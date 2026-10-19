import XCTest
@testable import FancamDuck

final class ExportValidationTests:XCTestCase {
    @MainActor func testPreviewAndExportBothRejectIncompleteOrInvalidSamplesBeforeReadingAsset() async throws {
        var p=VideoProject.demo;p.settings.end=0.4;p.target = .init(x:0.3,y:0.2,width:0.2,height:0.6)
        let body=p.target!
        let valid=(0...4).map {TargetSample(time:Double($0)*0.1,body:body)}
        XCTAssertNoThrow(try VideoExporter.validateTrajectory(valid,project:p))
        var invalidBody=valid;invalidBody[2] = .init(time:0.2,body:.init(x:-1,y:0,width:0.2,height:0.5))
        var invalidTime=valid;invalidTime[2] = .init(time:.nan,body:body)
        var invalidFocus=valid;invalidFocus[2].focusX = .nan
        var invalidProtection=valid;invalidProtection[2].protection = .init(x:0,y:0,width:2,height:2)
        let outside=[TargetSample(time:-0.1,body:body)]+valid
        let cases=[[TargetSample](),Array(valid.dropLast()),[valid[0],valid[4]],invalidBody,invalidTime,invalidFocus,invalidProtection,outside]
        let exporter=VideoExporter(),source=URL(fileURLWithPath:"/missing-video.mp4")
        for samples in cases {
            do { _=try await exporter.preview(source:source,project:p,samples:samples);XCTFail("Invalid preview accepted") }
            catch TrackingError.invalidTrajectory {} catch { XCTFail("Preview validated too late: \(error)") }
            do { _=try await exporter.exportMovingCrop(source:source,project:p,samples:samples);XCTFail("Invalid export accepted") }
            catch TrackingError.invalidTrajectory {} catch { XCTFail("Export validated too late: \(error)") }
        }
    }
    @MainActor func testAllOutputAspectsPreviewAndActualExportShareDimensions() async throws {
        let source=try TestVideoFixture.people()
        let metadata=try await MediaService.shared.metadata(url:source)
        for (aspect,size) in [(OutputAspectRatio.portrait,OutputResolution(width:180,height:320)),(.classic,.init(width:240,height:320)),(.square,.init(width:240,height:240))] {
            var project=VideoProject(title:"Aspect export",metadata:metadata,settings:EditSettings())
            project.target = .init(x:0.3,y:0.2,width:0.2,height:0.6)
            project.settings.end=0.4;project.settings.aspectRatio=aspect;project.settings.resolution=size
            let samples=(0...4).map {TargetSample(time:Double($0)/10,body:project.target!)}
            let chosen=try XCTUnwrap(CropPlan.make(samples:samples,source:metadata.size,settings:project.settings).first).rect
            project.settings.compositionAnchor = .init(time:0,crop:.init(x:chosen.minX/metadata.width,y:chosen.minY/metadata.height,width:chosen.width/metadata.width,height:chosen.height/metadata.height))
            let exporter=VideoExporter()
            let preview=try await exporter.preview(source:source,project:project,samples:samples)
            XCTAssertEqual(preview.videoComposition?.renderSize,CGSize(width:size.width,height:size.height))
            let output=try await exporter.exportMovingCrop(source:source,project:project,samples:samples)
            let result=try await MediaService.shared.metadata(url:output)
            XCTAssertEqual(result.width,Double(size.width));XCTAssertEqual(result.height,Double(size.height))
            XCTAssertEqual(result.duration,0.4,accuracy:0.05)
            try? FileManager.default.removeItem(at:output)
        }
    }
    func testExportUsesActualSourceFrameRateInsteadOfStaleCachedMetadata() async throws {
        let source=try TestVideoFixture.people()
        let actual=try await MediaService.shared.metadata(url:source)
        var p=VideoProject(title:"Stale FPS",metadata:.init(width:actual.width,height:actual.height,duration:actual.duration,frameRate:0),settings:EditSettings())
        p.target = .init(x:0.3,y:0.1,width:0.2,height:0.7);p.settings.end=0.4;p.settings.resolution = .init(width:180,height:320)
        let output=try await VideoExporter().exportFixedCrop(source:source,project:p)
        defer {try? FileManager.default.removeItem(at:output)}
        let result=try await MediaService.shared.metadata(url:output)
        XCTAssertEqual(result.frameRate,min(60,actual.frameRate),accuracy:0.01)
    }
}
