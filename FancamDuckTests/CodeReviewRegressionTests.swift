import XCTest
import AVFoundation
@testable import FancamDuck

private struct FailedPreviewExporter:VideoExporting {
    @MainActor func preview(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> AVPlayerItem {throw MediaError.exportFailed}
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> URL {throw MediaError.exportFailed}
}
private struct ReadyPreviewExporter:VideoExporting {
    @MainActor func preview(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> AVPlayerItem {AVPlayerItem(url:source)}
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> URL {throw MediaError.exportFailed}
}
final class CodeReviewRegressionTests:XCTestCase {
    @MainActor private func ready(_ model:AppModel) async throws {
        for _ in 0..<400 {if !model.compositionBusy {return};try await Task.sleep(for:.milliseconds(10))}
        XCTFail("Composition did not settle")
    }
    @MainActor private func movingDemo()->AppModel {
        let model=AppModel();model.startDemo()
        model.project?.metadata = .init(width:1920,height:1080,duration:1,frameRate:30)
        model.project?.settings.end=1
        let samples=(0...6).map {TargetSample(time:Double($0)/6,body:.init(x:0.15+Double($0)*0.08,y:0.25,width:0.08,height:0.3))}
        model.selectTarget(samples[0].body)
        model.targetSamples=samples;model.hasCompletedTracking=true
        return model
    }
    @MainActor func testSeekAndTrimSynchronizeAutomaticReferenceBeforeNextGesture() async throws {
        let model=movingDemo();defer {model.goHome()}
        model.beginComposition();try await ready(model)
        let initial=try XCTUnwrap(model.compositionCrop)
        model.seek(to:1)
        XCTAssertGreaterThan(abs(try XCTUnwrap(model.compositionCrop).midX-initial.midX),50)
        model.compositionMove(x:0,y:0)
        XCTAssertEqual(try XCTUnwrap(model.project?.settings.compositionX),0,accuracy:0.001)
        try await ready(model)
        model.resetComposition();try await ready(model)
        model.scrub(to:0.2,within:0...1,sourceOnly:true)
        model.compositionMove(x:0,y:0)
        XCTAssertEqual(try XCTUnwrap(model.project?.settings.compositionX),0,accuracy:0.001)
    }
    @MainActor func testReturnKeepsCropWhileProjectSwitchClearsIt() async throws {
        let model=movingDemo();defer {model.goHome()}
        model.beginComposition();try await ready(model)
        let crop=try XCTUnwrap(model.compositionCrop)
        model.backToEditor()
        XCTAssertTrue(model.hasCompletedTracking)
        model.beginComposition()
        XCTAssertEqual(model.compositionCrop,crop,"Returning to editing must retain the viewport during preparation")
        try await ready(model)
        model.startDemo()
        XCTAssertFalse(model.hasCompletedTracking)
        XCTAssertNil(model.compositionCrop,"The next project must not inherit the previous viewport")
    }
    @MainActor func testDemoCompositionPlaybackAdvancesTime() async throws {
        let model=movingDemo();defer {model.goHome()}
        model.beginComposition();try await ready(model)
        model.togglePreview()
        try await Task.sleep(for:.milliseconds(260))
        XCTAssertGreaterThan(model.currentTime,0.05)
        model.pausePreview(refresh:false)
    }
    @MainActor func testPreparingPreviewDoesNotRecordASuccessfulGeneration() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory)
        try await store.prepare();try Data([1]).write(to:directory.appendingPathComponent("source.mp4"))
        let model=AppModel(store:store,exporter:ReadyPreviewExporter())
        model.startDemo();model.project?.isDemo=false;model.project?.sourceFileName="source.mp4"
        model.project?.settings.end=1
        let box=DemoStage.body(index:1,time:0)
        model.selectTarget(box);model.hasCompletedTracking=true
        model.targetSamples=(0...6).map {.init(time:Double($0)/6,body:box)}
        model.confirmProcessing()
        for _ in 0..<400 {if model.phase == .readyToExport {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(model.phase,.readyToExport)
        XCTAssertNil(model.outputURL)
        model.project?.settings.followSpeed = .responsive
        XCTAssertFalse(model.needsRegeneration,"A preview is not a previously generated output")
        XCTAssertFalse(model.hasReusableOutput)
        model.goHome()
    }
    @MainActor func testUnavailablePreviewCannotEnterPlayingState() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory)
        try await store.prepare();try Data([1]).write(to:directory.appendingPathComponent("source.mp4"))
        let model=AppModel(store:store,exporter:FailedPreviewExporter())
        model.startDemo();model.project?.isDemo=false;model.project?.sourceFileName="source.mp4"
        model.project?.settings.end=1
        let box=DemoStage.body(index:1,time:0)
        model.selectTarget(box);model.hasCompletedTracking=true
        model.targetSamples=(0...6).map {.init(time:Double($0)/6,body:box)}
        model.beginComposition();try await ready(model)
        XCTAssertNil(model.previewPlayer)
        model.togglePreview()
        XCTAssertFalse(model.isPlaying)
        model.goHome()
    }
}
