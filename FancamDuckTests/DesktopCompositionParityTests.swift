import XCTest
import AVFoundation
import UIKit
@testable import FancamDuck

final class DesktopCompositionParityTests:XCTestCase {
    @MainActor func testDesktopCompositionPreviewMatchesExport() async throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_COMPOSITION_PARITY"]=="1" else {throw XCTSkip("Opt-in completed desktop composition export")}
        let temporary=FileManager.default.temporaryDirectory
        let project=try JSONDecoder().decode(VideoProject.self,from:Data(contentsOf:temporary.appendingPathComponent("FancamDuck-export-project.json")))
        XCTAssertEqual(project.metadata.width,3840);XCTAssertGreaterThan(abs(project.settings.compositionX)+abs(project.settings.compositionY),0.01)
        XCTAssertGreaterThan(abs(project.settings.compositionScale-1),0.02)
        let samples=try JSONDecoder().decode([TargetSample].self,from:Data(contentsOf:temporary.appendingPathComponent("FancamDuck-export-trajectory.json")))
        // Compare the viewport actually committed BEFORE full inference with the final camera.
        let selectedFile=temporary.appendingPathComponent("FancamDuck-selected-\(project.id).json")
        let chosen=try JSONDecoder().decode(VideoProject.self,from:Data(contentsOf:selectedFile))
        XCTAssertEqual(chosen.id,project.id)
        let anchor=try XCTUnwrap(chosen.settings.compositionAnchor)
        XCTAssertEqual(project.settings.compositionAnchor,anchor,"Processing must retain the user's selected viewport")
        let path=CropPlan.renderFrames(CropPlan.make(samples:samples,source:project.metadata.size,settings:project.settings),frameRate:project.metadata.frameRate,preserving:anchor.time)
        let reference=try XCTUnwrap(CropPlan.rect(at:anchor.time,in:path))
        XCTAssertEqual(reference.minX,anchor.crop.x*project.metadata.width,accuracy:0.001)
        XCTAssertEqual(reference.minY,anchor.crop.y*project.metadata.height,accuracy:0.001)
        XCTAssertEqual(reference.height,anchor.crop.height*project.metadata.height,accuracy:0.001)
        print("SELECTED_VIEWPORT_RETAINED time=\(anchor.time) crop=\(reference)")
        let name=try String(contentsOf:temporary.appendingPathComponent("FancamDuck-export-name.txt"),encoding:.utf8)
        let stored=try await ProjectStore.shared.output(for:project)
        let output=stored?.url ?? temporary.appendingPathComponent(name)
        let source=try XCTUnwrap(ProjectStore.shared.sourceURL(for:project))
        let item=try await VideoExporter().preview(source:source,project:project,samples:samples)
        let preview=AVAssetImageGenerator(asset:item.asset);preview.videoComposition=item.videoComposition
        let exported=AVAssetImageGenerator(asset:AVURLAsset(url:output))
        for generator in [preview,exported] {
            generator.appliesPreferredTrackTransform=true;generator.maximumSize = .init(width:360,height:640)
            generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        }
        struct Match:Codable {let time:Double;let meanAbsoluteRGBError:Double;let correlation:Double}
        var matches:[Match]=[]
        func pixels(_ image:CGImage) throws -> [Double] {
            let w=360,h=640
            var bytes=Array(repeating:UInt8(0),count:w*h*4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context=try XCTUnwrap(CGContext(data:buffer.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.interpolationQuality = .high
                context.draw(image,in:.init(x:0,y:0,width:w,height:h))
            }
            return bytes.indices.filter {$0%4 != 3}.map {Double(bytes[$0])/255}
        }
        let original=AVAssetImageGenerator(asset:AVURLAsset(url:source))
        original.appliesPreferredTrackTransform=true
        original.requestedTimeToleranceBefore = .zero;original.requestedTimeToleranceAfter = .zero
        let sourceFrame=try await original.image(at:CMTime(seconds:anchor.time,preferredTimescale:60000)).image
        let selectedPixels=try XCTUnwrap(sourceFrame.cropping(to:CGRect(x:anchor.crop.x*Double(sourceFrame.width),y:anchor.crop.y*Double(sourceFrame.height),width:anchor.crop.width*Double(sourceFrame.width),height:anchor.crop.height*Double(sourceFrame.height))))
        for seconds in [0.0,5,18,32,37.8] {
            let time=CMTime(seconds:seconds,preferredTimescale:60000)
            let a=try await preview.image(at:time).image,b=try await exported.image(at:time).image
            XCTAssertEqual(a.width,b.width);XCTAssertEqual(a.height,b.height)
            let x=try pixels(a),y=try pixels(b)
            let n=Double(x.count),mx=x.reduce(0,+)/n,my=y.reduce(0,+)/n
            var error=0.0,covariance=0.0,vx=0.0,vy=0.0
            for i in x.indices {error+=abs(x[i]-y[i]);covariance+=(x[i]-mx)*(y[i]-my);vx+=pow(x[i]-mx,2);vy+=pow(y[i]-my,2)}
            let mae=error/n,correlation=covariance/sqrt(vx*vy)
            XCTAssertLessThan(mae,0.025,"Preview/export crop mismatch at \(seconds)")
            XCTAssertGreaterThan(correlation,0.98)
            if abs(seconds-(anchor.time-project.settings.start))<0.0001 {
                let expected=try pixels(selectedPixels)
                let directError=zip(expected,y).map {abs($0-$1)}.reduce(0,+)/n
                XCTAssertLessThan(directError,0.025,"Encoded video must match the source viewport selected before inference")
                print("SELECTED_SOURCE_VS_EXPORT_RGB_ERROR=\(directError)")
                let attachment=XCTAttachment(image:UIImage(cgImage:selectedPixels));attachment.name="selected-before-processing-source-crop";attachment.lifetime = .keepAlways;add(attachment)
            }
            matches.append(.init(time:seconds,meanAbsoluteRGBError:mae,correlation:correlation))
            for (label,image) in [("preview",a),("export",b)] {
                let attachment=XCTAttachment(image:UIImage(cgImage:image));attachment.name="composition-\(seconds)-\(label)";attachment.lifetime = .keepAlways;add(attachment)
            }
        }
        let data=try JSONEncoder().encode(matches)
        try data.write(to:temporary.appendingPathComponent("FancamDuck-composition-parity.json"),options:.atomic)
        print("COMPOSITION_PARITY \(String(decoding:data,as:UTF8.self))")
    }
}
