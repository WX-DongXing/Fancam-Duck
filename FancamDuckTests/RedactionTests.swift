import XCTest
import AVFoundation
import CoreImage
import UIKit
@testable import FancamDuck

final class RedactionTests: XCTestCase {
    private func observation(id:Int=1,x:Double=0.4,feature:[Float]=[1,0]) -> PersonObservation {
        var points=(0..<17).map {_ in PosePoint(x:x+0.08,y:0.4,confidence:0)}
        points[0] = .init(x:x+0.08,y:0.25,confidence:0.9)
        points[1] = .init(x:x+0.06,y:0.24,confidence:0.9)
        points[2] = .init(x:x+0.10,y:0.24,confidence:0.9)
        points[5] = .init(x:x+0.02,y:0.34,confidence:0.9)
        points[6] = .init(x:x+0.14,y:0.34,confidence:0.9)
        return .init(id:id,body:.init(x:x,y:0.2,width:0.17,height:0.65),confidence:0.95,keypoints:points,embedding:feature)
    }
    func testAutomaticMasksAllBystandersAndNewEntrantsButNeverPrimary() throws {
        var project=VideoProject.demo;project.settings.start=0;project.settings.end=1
        project.settings.redaction = .init(allOthers:true)
        let primary=observation(id:1,x:0.4),other=observation(id:2,x:0.05,feature:[0,1]),entrant=observation(id:3,x:0.75,feature:[-1,0])
        project.target=primary.body
        let frames=(0...10).map { index -> (Double,DetectionBatch) in
            var people=[primary,other]
            if index>=5 {people.append(entrant)}
            // Face landmarks may disappear without dropping the mask.
            if index==7 {people[1].keypoints=[]}
            return (Double(index)/10,.init(primary:people,relaxed:[]))
        }
        let samples=(0...10).map {TargetSample(time:Double($0)/10,body:primary.body)}
        let plan=try AutomaticRedaction.build(frames:frames,project:project,samples:samples)
        XCTAssertTrue(plan.covers(project))
        var changed=project;changed.target=other.body
        XCTAssertFalse(plan.covers(changed))
        XCTAssertEqual(plan.rectangles(at:0.2).count,1)
        XCTAssertEqual(plan.rectangles(at:0.7).count,2)
        XCTAssertEqual(plan.rectangles(at:0.45).count,2,"Look-ahead must protect between detection samples")
        XCTAssertEqual(plan.rectangles(at:1).count,2)
        for track in plan.tracks {for frame in track.bodies {XCTAssertLessThan(frame.rect.iou(primary.body),0.1)}}
        let decoded=try JSONDecoder().decode(RedactionPlan.self,from:JSONEncoder().encode(plan))
        XCTAssertTrue(decoded.covers(project.settings))
        var missing=plan;missing.automaticTimes?.remove(at:4)
        XCTAssertFalse(missing.covers(project.settings))
        XCTAssertThrowsError(try AutomaticRedaction.build(frames:frames,project:project,samples:[]))
        let enabled=try JSONDecoder().decode(RedactionSettings.self,from:JSONEncoder().encode(project.settings.redaction))
        XCTAssertTrue(enabled.enabled);XCTAssertTrue(enabled.subjects.isEmpty)
    }
    func testAutomaticExclusionFollowsPrimaryRatherThanDetectionNumber() throws {
        let left=observation(id:1,x:0.05),right=observation(id:2,x:0.7)
        XCTAssertEqual(AutomaticRedaction.candidates([left,right],primary:right.body).map(\.id),[left.id])
        XCTAssertEqual(AutomaticRedaction.candidates([right,left],primary:left.body).map(\.id),[right.id])
    }
    func testAutomaticMasksAllowBystanderPredictionToLeaveFrame() throws {
        var project=VideoProject.demo;project.settings.start=0;project.settings.end=1.6
        project.settings.redaction = .init(region:.person,allOthers:true)
        let primary=observation(id:1,x:0.1)
        project.target=primary.body
        let frames=(0...16).map { index -> (Double,DetectionBatch) in
            var people=[primary]
            if index<8 {
                let other=PersonObservation(id:2,body:.init(x:0.72+Double(index)*0.03,y:0.2,width:0.05,height:0.65),confidence:0.95,keypoints:[],embedding:[0,1])
                people.append(other)
            }
            return (Double(index)/10,.init(primary:people,relaxed:[]))
        }
        let samples=(0...16).map {TargetSample(time:Double($0)/10,body:primary.body)}
        let plan=try AutomaticRedaction.build(frames:frames,project:project,samples:samples)
        XCTAssertTrue(plan.covers(project))
        XCTAssertFalse(plan.rectangles(at:0.5).isEmpty)
        XCTAssertTrue(plan.rectangles(at:1.6).isEmpty)
    }
    func testSmoothingAlwaysContainsObservationsAndDoesNotFlicker() throws {
        let input=(0...30).map { index -> RedactionFrame in
            let jitter=index.isMultiple(of:2) ? 0.006 : -0.006
            let width=index==15 ? 0.11 : 0.09
            return .init(time:Double(index)/10,rect:.init(x:0.2+Double(index)*0.004+jitter,y:0.2,width:width,height:0.13))
        }
        let smooth=RedactionMotion.smooth(input)
        XCTAssertEqual(smooth.count,input.count)
        for (raw,frame) in zip(input,smooth) {
            XCTAssertTrue(frame.rect.isValid)
            XCTAssertLessThanOrEqual(frame.rect.x,raw.rect.x)
            XCTAssertGreaterThanOrEqual(frame.rect.x+frame.rect.width,raw.rect.x+raw.rect.width)
            XCTAssertLessThanOrEqual(frame.rect.y,raw.rect.y)
            XCTAssertGreaterThanOrEqual(frame.rect.y+frame.rect.height,raw.rect.y+raw.rect.height)
        }
        let rawJerk=zip(input,input.dropFirst()).map {abs($1.rect.center.x-$0.rect.center.x)}.max()!
        let smoothStep=zip(smooth,smooth.dropFirst()).map {abs($1.rect.center.x-$0.rect.center.x)}.max()!
        XCTAssertLessThan(smoothStep,rawJerk)
        for index in 0...180 {
            let rect=try XCTUnwrap(RedactionPlan.rectangle(at:Double(index)/60,frames:smooth))
            XCTAssertTrue(rect.isValid)
        }
    }
    func testFaceMaskIncludesLandmarksAndPhysicalAspectAcrossVideoSizes() throws {
        for source in [CGSize(width:3840,height:2160),CGSize(width:1080,height:1920),CGSize(width:1080,height:1080)] {
            let person=observation(),head=try XCTUnwrap(RedactionMotion.head(of:person,source:source))
            for point in person.keypoints.prefix(3) {XCTAssertTrue(head.cgRect.contains(CGPoint(x:point.x,y:point.y)))}
            XCTAssertTrue(head.isValid)
            XCTAssertEqual(head.width*source.width/(head.height*source.height),1.3/1.55,accuracy:0.001)
        }
    }
    func testLongHeadOcclusionBlocksInsteadOfSilentlyDroppingMask() throws {
        let person=observation(),subject=RedactionSubject(anchors:[.init(time:0,body:person.body)])
        var hidden=person;hidden.keypoints=[]
        let frames=(0...10).map {(Double($0)/10,DetectionBatch(primary:[$0==0 ? person : hidden],relaxed:[]))}
        let result=try RedactionTracker.trace(seed:.init(primary:[person],relaxed:[]),anchor:subject.anchors[0],frames:frames,options:.init(subjects:[subject]),source:.init(width:1920,height:1080),subjectID:subject.id)
        XCTAssertNotNil(result.issue)
        XCTAssertEqual(result.issue?.subjectID,subject.id)
        XCTAssertTrue(result.frames.isEmpty)
    }
    func testMultiPersonTracksRemainIndependentAndContinuous() throws {
        let a=observation(),b=observation(id:2,x:0.7,feature:[0,1])
        let seed=DetectionBatch(primary:[a,b],relaxed:[])
        let frames=(0...10).map {(Double($0)/10,seed)}
        for person in [a,b] {
            let subject=RedactionSubject(anchors:[.init(time:0,body:person.body)])
            let result=try RedactionTracker.trace(seed:seed,anchor:subject.anchors[0],frames:frames,options:.init(subjects:[subject]),source:.init(width:1920,height:1080),subjectID:subject.id)
            XCTAssertNil(result.issue);XCTAssertEqual(result.frames.count,11)
            XCTAssertEqual(result.frames.first?.rect,result.frames.last?.rect)
        }
    }
    func testLegacyProjectAndSettingsDecodeWithoutRedaction() throws {
        let settings=try JSONDecoder().decode(EditSettings.self,from:Data("{}".utf8))
        XCTAssertFalse(settings.redaction.enabled)
        let project=try JSONDecoder().decode(VideoProject.self,from:JSONEncoder().encode(VideoProject.demo))
        XCTAssertNil(project.redactionPlan)
    }
    func testPlanRejectsGapsWrongIdentityAndChangedRegionButAllowsStrengthChange() throws {
        let person=observation(),subject=RedactionSubject(anchors:[.init(time:0,body:person.body)])
        var settings=EditSettings();settings.end=1;settings.redaction.subjects=[subject]
        let track=RedactionTrack(subjectID:subject.id,frames:(0...10).map {.init(time:Double($0)/10,rect:person.body)})
        var plan=RedactionPlan(subjects:[subject],region:.face,start:0,end:1,tracks:[track])
        XCTAssertTrue(plan.covers(settings))
        settings.redaction.strength=0.8;XCTAssertTrue(plan.covers(settings))
        settings.redaction.region = .person;XCTAssertFalse(plan.covers(settings))
        settings.redaction.region = .face
        plan.tracks[0].frames.remove(at:5);XCTAssertFalse(plan.covers(settings))
        plan.tracks=[track];plan.tracks[0].subjectID=UUID();XCTAssertFalse(plan.covers(settings))
    }
    @MainActor func testActualRedactedPreviewAndExportMatchAcrossAspects() async throws {
        let source=try TestVideoFixture.people()
        let metadata=try await MediaService.shared.metadata(url:source)
        let sticker=UIGraphicsImageRenderer(size:CGSize(width:64,height:32)).image { context in
            UIColor.systemOrange.setFill();context.fill(CGRect(x:0,y:0,width:64,height:32))
        }.pngData()!
        for (aspect,style) in OutputAspectRatio.allCases.flatMap({aspect in RedactionSettings.Style.allCases.map {(aspect,$0)}}) {
            var project=VideoProject(title:"Redaction parity",metadata:metadata,settings:.init())
            project.target = .init(x:0.3,y:0.1,width:0.25,height:0.8)
            project.settings.end=0.4;project.settings.aspectRatio=aspect
            project.settings.resolution = .init(width:Int((240*aspect.value/2).rounded())*2,height:240)
            let subject=RedactionSubject(anchors:[.init(time:0,body:.init(x:0.7,y:0.1,width:0.2,height:0.7))])
            project.settings.redaction = .init(subjects:[subject],region:.person,style:style,imageData:sticker)
            let frames=(0...4).map {RedactionFrame(time:Double($0)/10,rect:.init(x:0,y:0,width:1,height:1))}
            project.redactionPlan = .init(subjects:[subject],region:.person,start:0,end:0.4,tracks:[.init(subjectID:subject.id,frames:frames)])
            let samples=(0...4).map {TargetSample(time:Double($0)/10,body:project.target!)}
            let exporter=VideoExporter(),item=try await exporter.preview(source:source,project:project,samples:samples)
            XCTAssertTrue(item.videoComposition?.customVideoCompositorClass == RedactionCompositor.self)
            let generator=AVAssetImageGenerator(asset:item.asset);generator.videoComposition=item.videoComposition
            generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            let expected=try await generator.image(at:CMTime(seconds:0.2,preferredTimescale:600)).image
            let output=try await exporter.exportMovingCrop(source:source,project:project,samples:samples)
            defer {try? FileManager.default.removeItem(at:output)}
            let actualGenerator=AVAssetImageGenerator(asset:AVURLAsset(url:output));actualGenerator.appliesPreferredTrackTransform=true
            actualGenerator.requestedTimeToleranceBefore = .zero;actualGenerator.requestedTimeToleranceAfter = .zero
            let actual=try await actualGenerator.image(at:CMTime(seconds:0.2,preferredTimescale:600)).image
            let folder=FileManager.default.temporaryDirectory
            try CIContext().writePNGRepresentation(of:CIImage(cgImage:expected),to:folder.appendingPathComponent("redaction-expected-"+aspect.rawValue.replacingOccurrences(of:":",with:"-")+".png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            try CIContext().writePNGRepresentation(of:CIImage(cgImage:actual),to:folder.appendingPathComponent("redaction-actual-"+aspect.rawValue.replacingOccurrences(of:":",with:"-")+".png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            print("REDACTION_PIXEL_IMAGES=\(folder.path) expectedColor=\(String(describing:expected.colorSpace)) actualColor=\(String(describing:actual.colorSpace))")
            XCTAssertEqual(expected.width,actual.width);XCTAssertEqual(expected.height,actual.height)
            XCTAssertLessThan(Self.meanDifference(expected,actual),8)
        }
    }
    func testCompositionViewportAndExportMatchWhenMaskCrossesCropEdge() throws {
        let bounds=CGRect(x:0,y:0,width:256,height:256),context=CIContext()
        let source=try XCTUnwrap(CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":8])?.outputImage).cropped(to:bounds)
        let box=NormalizedRect(x:0.15,y:0.15,width:0.7,height:0.7)
        let crop=CGRect(x:64,y:64,width:128,height:128)
        let sticker=CIImage(color:CIColor(red:0.2,green:0.5,blue:1)).cropped(to:CGRect(x:0,y:0,width:32,height:16))
        for scale in [0.5,1.0] {
            for style in RedactionSettings.Style.allCases {
                let full=RedactionRenderer.render(source,source:bounds.size,crop:bounds,output:CGSize(width:256*scale,height:256*scale),boxes:[box],strength:0.65,style:style,sticker:sticker)
                let expected=full.cropped(to:CGRect(x:64*scale,y:64*scale,width:128*scale,height:128*scale))
                    .transformed(by:.init(translationX:-64*scale,y:-64*scale))
                let actual=RedactionRenderer.render(source,source:bounds.size,crop:crop,output:CGSize(width:128*scale,height:128*scale),boxes:[box],strength:0.65,style:style,sticker:sticker)
                let extent=CGRect(x:0,y:0,width:128*scale,height:128*scale)
                XCTAssertLessThan(Self.meanDifference(try XCTUnwrap(context.createCGImage(expected,from:extent)),try XCTUnwrap(context.createCGImage(actual,from:extent))),0.1,style.rawValue)
            }
        }
    }
    func testImageOverlayHasNoBackingOrShadowAndOverscansCoverage() throws {
        let size=64,row=size*4
        var bytes=[UInt8](repeating:255,count:size*row)
        for y in 0..<size {for x in 0..<size {
            let value:UInt8=(x/2+y/2).isMultiple(of:2) ? 0 : 255
            for c in 0..<3 {bytes[y*row+x*4+c]=value}
        }}
        let source=CIImage(bitmapData:Data(bytes),bytesPerRow:row,size:CGSize(width:size,height:size),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        let bounds=CGRect(x:0,y:0,width:size,height:size),context=CIContext()
        let original=try XCTUnwrap(context.createCGImage(source,from:bounds))
        let box=NormalizedRect(x:0.25,y:0.25,width:0.5,height:0.5)
        let transparent=CIImage(color:CIColor(red:1,green:0,blue:0,alpha:0)).cropped(to:CGRect(x:0,y:0,width:16,height:8))
        let frosted=RedactionRenderer.render(source,source:bounds.size,crop:bounds,output:bounds.size,boxes:[box],strength:0.65,style:.frosted)
        let image=RedactionRenderer.render(source,source:bounds.size,crop:bounds,output:bounds.size,boxes:[box],strength:0.65,style:.image,sticker:transparent)
        let a=try XCTUnwrap(context.createCGImage(frosted,from:bounds)),b=try XCTUnwrap(context.createCGImage(image,from:bounds))
        XCTAssertGreaterThan(Self.meanDifference(a,b),10,"Image mode must not also apply frosted video")
        XCTAssertLessThan(Self.meanDifference(original,b),0.01,"Transparent pixels must not create an external dark backing")
        XCTAssertGreaterThan(Self.meanDifference(original,a),20,"The filter must actually obscure source detail")
        let untouched=CGRect(x:0,y:0,width:8,height:8)
        XCTAssertLessThan(Self.meanDifference(try XCTUnwrap(context.createCGImage(source,from:untouched)),try XCTUnwrap(context.createCGImage(image,from:untouched))),0.01)
        let sticker=CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:16,height:8))
        let covered=RedactionRenderer.render(source,source:bounds.size,crop:bounds,output:bounds.size,boxes:[box],strength:0.65,style:.image,sticker:sticker)
        var pixel=[UInt8](repeating:0,count:4)
        context.render(covered,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:32,y:32,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        XCTAssertGreaterThan(pixel[0],240);XCTAssertLessThan(pixel[1],10)
        context.render(covered,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:16,y:17,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        XCTAssertGreaterThan(pixel[0],240);XCTAssertLessThan(pixel[1],10,"Aspect fill must cover the full mask height without letterboxing")
        let outside=CGRect(x:12,y:16,width:4,height:32)
        XCTAssertLessThan(Self.meanDifference(try XCTUnwrap(context.createCGImage(source,from:outside)),try XCTUnwrap(context.createCGImage(covered,from:outside))),0.01,"Enlarging the image must not expand onto neighboring people")

    }
    @MainActor func testImagePreparationTrimsTransparentPaddingAndRejectsInvisibleImage() throws {
        let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=false
        let renderer=UIGraphicsImageRenderer(size:CGSize(width:64,height:64),format:format)
        let padded=renderer.image {context in
            UIColor.red.setFill();context.fill(CGRect(x:4,y:7,width:16,height:10))
        }
        let prepared=try RedactionImage.prepare(try XCTUnwrap(padded.pngData()))
        let decoded=try XCTUnwrap(RedactionImage.decode(prepared))
        XCTAssertEqual(decoded.width,16);XCTAssertEqual(decoded.height,10)
        var pixel=[UInt8](repeating:0,count:4)
        CIContext().render(CIImage(cgImage:decoded),toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:8,y:5,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        XCTAssertGreaterThan(pixel[0],240);XCTAssertLessThan(pixel[1],10);XCTAssertEqual(pixel[3],255)
        let empty=renderer.image {_ in}
        XCTAssertThrowsError(try RedactionImage.prepare(try XCTUnwrap(empty.pngData())))
    }
    private static func meanDifference(_ a:CGImage,_ b:CGImage) -> Double {
        let context=CIContext(),bounds=CGRect(x:0,y:0,width:a.width,height:a.height)
        let count=a.width*a.height*4
        var left=[UInt8](repeating:0,count:count),right=left
        context.render(CIImage(cgImage:a),toBitmap:&left,rowBytes:a.width*4,bounds:bounds,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        context.render(CIImage(cgImage:b),toBitmap:&right,rowBytes:b.width*4,bounds:bounds,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        return zip(left,right).enumerated().filter {$0.offset%4 != 3}.reduce(0.0) {$0+abs(Double($1.element.0)-Double($1.element.1))}/Double(a.width*a.height*3)
    }
}
