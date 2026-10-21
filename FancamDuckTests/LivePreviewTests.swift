import XCTest
@testable import FancamDuck

final class LivePreviewTests:XCTestCase {
    @MainActor private func ready(_ model:AppModel) async throws {
        for _ in 0..<500 {if !model.compositionBusy {return};try await Task.sleep(for:.milliseconds(10))}
        XCTFail("Preview did not become ready")
    }
    @MainActor func testLiveChangesResumeLatestPlaybackAndPauseCancelsWaiting() async throws {
        let model=AppModel();model.startDemo();defer {model.goHome()}
        let body=DemoStage.body(index:1,time:0)
        model.selectTarget(body);model.targetSamples=[.init(time:0,body:body),.init(time:58.2,body:body)]
        model.hasCompletedTracking=true;model.beginComposition();try await ready(model)
        model.seek(to:20);model.togglePreview();XCTAssertTrue(model.isPlaying)
        model.setFollowSpeed(.responsive)
        XCTAssertFalse(model.isPlaying);XCTAssertTrue(model.previewPlaybackPending)
        try await ready(model)
        XCTAssertTrue(model.isPlaying)
        model.setCompositionAspect(.square)
        XCTAssertTrue(model.previewPlaybackPending)
        model.pausePreview(refresh:false)
        try await ready(model)
        XCTAssertFalse(model.isPlaying);XCTAssertFalse(model.previewPlaybackPending)
        model.togglePreview();model.skipPreview(by:5)
        XCTAssertTrue(model.isPlaying);XCTAssertEqual(model.currentTime,25,accuracy:0.2)
        model.skipPreview(by:-100)
        XCTAssertEqual(model.currentTime,0,accuracy:0.1)
        model.pausePreview(refresh:false)
        XCTAssertNil(model.outputURL)
    }
    @MainActor func testOpenExportKeepsPreviewPositionAndDoesNotGenerateVideo() async throws {
        let model=AppModel();model.startDemo();defer {model.goHome()}
        let body=DemoStage.body(index:1,time:0)
        model.selectTarget(body);model.targetSamples=[.init(time:0,body:body),.init(time:58.2,body:body)]
        model.hasCompletedTracking=true;model.beginComposition();try await ready(model)
        model.seek(to:12)
        await model.openExportPreview()
        XCTAssertEqual(model.route,.export);XCTAssertEqual(model.phase,.readyToExport)
        XCTAssertNil(model.outputURL)
        model.backToEditor()
        XCTAssertEqual(model.currentTime,12,accuracy:0.001)
        XCTAssertTrue(model.hasCompletedTracking)
        model.beginComposition();model.setFollowSpeed(.responsive);model.togglePreview()
        XCTAssertTrue(model.previewPlaybackPending)
        model.goHome();try await Task.sleep(for:.milliseconds(80))
        XCTAssertFalse(model.isPlaying);XCTAssertFalse(model.previewPlaybackPending)
    }
}
