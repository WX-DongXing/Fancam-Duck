import XCTest
import AVFoundation
import CoreImage
@testable import FancamDuck

/// Explicit desktop integration run. Uses the same original as the simulator Photos validation.
final class RedactionDesktopValidationTests: XCTestCase {
    @MainActor func testDesktopMultiPersonRedactionAndExport() async throws {
        let source=URL(fileURLWithPath:"/Users/xingdong/Desktop/video_1774105867371.mp4")
        guard FileManager.default.fileExists(atPath:source.path) else {throw XCTSkip("Desktop original is not available on this host")}
        let metadata=try await MediaService.shared.metadata(url:source),pipeline=CoreMLTrackingPipeline()
        let people=try await pipeline.detections(source:source,time:0,region:nil).sorted {$0.body.center.x<$1.body.center.x}
        XCTAssertGreaterThanOrEqual(people.count,5)
        let main=people[2]
        var project=VideoProject(title:"Desktop redaction review",metadata:metadata,settings:.init())
        project.target=main.body;project.settings.end=2;project.settings.personHeight=0.35;project.settings.aspectRatio = .square;project.settings.resolution = .init(width:640,height:640)
        project.settings.redaction = .init(allOthers:true)
        let began=Date()
        let tracked=try await pipeline.analyze(source:source,project:project,onUpdate:{_ in})
        XCTAssertNil(tracked.issue);guard tracked.issue == nil else {return}
        let trackingMetrics=await pipeline.performanceMetrics()
        let afterTracking=try XCTUnwrap(trackingMetrics)
        var report:[String:Any]=["sourceWidth":metadata.width,"sourceHeight":metadata.height,"seconds":2,"scope":"all-except-primary","trackingSeconds":Date().timeIntervalSince(began)]
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("redaction-desktop-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let sticker=try Data(contentsOf:try XCTUnwrap(Bundle(for:Self.self).url(forResource:"redaction-sticker",withExtension:"png")))
        for (region,style) in RedactionSettings.Region.allCases.flatMap({region in RedactionSettings.Style.allCases.map {(region,$0)}}) {
            project.settings.redaction.region=region;project.settings.redaction.style=style
            project.settings.redaction.imageData=try RedactionImage.prepare(sticker)
            project.redactionPlan=nil
            let started=Date()
            let result=try await pipeline.redactions(source:source,project:project,samples:tracked.samples,onProgress:{_ in})
            XCTAssertNil(result.issue,"\(result.issue?.message ?? "") at \(result.issue?.time ?? -1)")
            let plan=try XCTUnwrap(result.plan);XCTAssertTrue(plan.covers(project.settings))
            project.redactionPlan=plan
            let masksMetrics=await pipeline.performanceMetrics()
            let afterMasks=try XCTUnwrap(masksMetrics)
            XCTAssertEqual(afterMasks.poseCalls,afterTracking.poseCalls,"Mask subjects must reuse the same detections")
            report[region.rawValue+style.rawValue+"AnalysisSeconds"]=Date().timeIntervalSince(started)
            report[region.rawValue+style.rawValue+"AdditionalPoseCalls"]=afterMasks.poseCalls-afterTracking.poseCalls
            let exporter=VideoExporter(),preview=try await exporter.preview(source:source,project:project,samples:tracked.samples)
            let exportStart=Date(),output=try await exporter.exportMovingCrop(source:source,project:project,samples:tracked.samples)
            report[region.rawValue+style.rawValue+"ExportSeconds"]=Date().timeIntervalSince(exportStart)
            let name=(region == .face ? "face" : "person")+"-"+(style == .frosted ? "frosted" : style == .mosaic ? "mosaic" : "image")
            try FileManager.default.copyItem(at:output,to:folder.appendingPathComponent(name+".mp4"))
            let generator=AVAssetImageGenerator(asset:preview.asset);generator.videoComposition=preview.videoComposition
            generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            for time in [0.0,0.5,1.0,1.5] {
                let image=try await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
                try CIContext().writePNGRepresentation(of:CIImage(cgImage:image),to:folder.appendingPathComponent("\(name)-\(time).png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            }
            try JSONEncoder().encode(plan).write(to:folder.appendingPathComponent(name+"-plan.json"))
        }
        var plain=project;plain.settings.redaction.allOthers=false;plain.settings.redaction.subjects=[];plain.redactionPlan=nil
        let baseStart=Date(),baseline=try await VideoExporter().exportMovingCrop(source:source,project:plain,samples:tracked.samples)
        report["unmaskedExportSeconds"]=Date().timeIntervalSince(baseStart)
        try FileManager.default.copyItem(at:baseline,to:folder.appendingPathComponent("baseline.mp4"))
        // Check actual encoded output pixels, not just a valid plan or compositor type.
        var controlProject=project
        controlProject.redactionPlan?.tracks=[]
        let control=try await VideoExporter().exportMovingCrop(source:source,project:controlProject,samples:tracked.samples)
        defer {try? FileManager.default.removeItem(at:control)}
        let time=0.5,stamp=CMTime(seconds:0.5,preferredTimescale:600)
        let baselineGenerator=AVAssetImageGenerator(asset:AVURLAsset(url:control))
        baselineGenerator.requestedTimeToleranceBefore = .zero;baselineGenerator.requestedTimeToleranceAfter = .zero
        let base=CIImage(cgImage:try await baselineGenerator.image(at:stamp).image)
        let path=CropPlan.renderFrames(CropPlan.make(samples:tracked.samples,source:metadata.size,settings:project.settings),frameRate:metadata.frameRate)
        let crop=try XCTUnwrap(CropPlan.rect(at:time,in:path)),scale=640/crop.width
        func outputRect(_ rect:NormalizedRect) -> CGRect {
            CGRect(x:(rect.x*metadata.width-crop.minX)*scale,
                   y:(crop.maxY-(rect.y+rect.height)*metadata.height)*scale,
                   width:rect.width*metadata.width*scale,height:rect.height*metadata.height*scale)
        }
        let mainBody=try XCTUnwrap(RedactionPlan.rectangle(at:time,frames:tracked.samples.map {.init(time:$0.time,rect:$0.body)}))
        let mainFace=outputRect(.init(x:mainBody.x+mainBody.width*0.2,y:mainBody.y,width:mainBody.width*0.6,height:mainBody.height*0.15))
        for region in ["face","person"] {for style in ["frosted","mosaic","image"] {
            let name=region+"-"+style
            let gen=AVAssetImageGenerator(asset:AVURLAsset(url:folder.appendingPathComponent(name+".mp4")))
            gen.requestedTimeToleranceBefore = .zero;gen.requestedTimeToleranceAfter = .zero
            let actual=CIImage(cgImage:try await gen.image(at:stamp).image)
            let maskPlan=try JSONDecoder().decode(RedactionPlan.self,from:Data(contentsOf:folder.appendingPathComponent(name+"-plan.json")))
            let regions=maskPlan.rectangles(at:time).map(outputRect).map {$0.intersection(base.extent)}.filter {!$0.isNull && $0.width>10 && $0.height>10}
            XCTAssertGreaterThanOrEqual(regions.count,2,"Bystanders must be visible in the verification composition")
            for box in regions {
                let difference=Self.difference(base,actual,in:box.insetBy(dx:box.width*0.25,dy:box.height*0.25))
                XCTAssertGreaterThan(difference,1,"Actual output must shade each visible bystander: \(name)")
            }
            XCTAssertTrue(regions.allSatisfy {!$0.intersects(mainFace)},"No bystander mask may cover the primary face")
            let primaryDifference=Self.difference(base,actual,in:mainFace)
            XCTAssertLessThan(primaryDifference,4,"The primary must stay clear: \(name)")
            report[name+"PrimaryPixelDifference"]=primaryDifference
        }}
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("metrics.json"))
        print("REDACTION_DESKTOP_ARTIFACTS=\(folder.path)")
        print("REDACTION_DESKTOP_METRICS=\(report)")
    }
    private static func difference(_ a:CIImage,_ b:CIImage,in rect:CGRect) -> Double {
        let rect=rect.integral.intersection(a.extent),width=Int(rect.width),height=Int(rect.height)
        guard width>0,height>0 else {return .infinity}
        var left=[UInt8](repeating:0,count:width*height*4),right=left
        let context=CIContext(),color=CGColorSpace(name:CGColorSpace.sRGB)!
        context.render(a,toBitmap:&left,rowBytes:width*4,bounds:rect,format:.RGBA8,colorSpace:color)
        context.render(b,toBitmap:&right,rowBytes:width*4,bounds:rect,format:.RGBA8,colorSpace:color)
        var sum=0.0
        for index in left.indices where index%4 != 3 {sum += abs(Double(left[index])-Double(right[index]))}
        return sum/Double(width*height*3)
    }

}
