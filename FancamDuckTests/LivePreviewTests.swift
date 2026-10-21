import XCTest
@testable import FancamDuck

final class LivePreviewTests:XCTestCase {
    @MainActor func testAnalyzedHistoryShowsPreviewWhileRestoringWithoutGrantingPlayback() {
        let model=AppModel();model.startDemo();defer {model.goHome()}
        model.project?.progressState="已分析 · 可预览"
        model.restoringTracking=true
        XCTAssertTrue(model.showsPreviewSettings)
        XCTAssertFalse(model.hasCompletedTracking)
        XCTAssertFalse(model.settingsEnabled)
        XCTAssertNil(model.editorActivityText)
        XCTAssertEqual(model.statusText,"预览")
        model.togglePreview()
        XCTAssertFalse(model.isPlaying)
        model.restoringTracking=false
        XCTAssertFalse(model.showsPreviewSettings,"Invalid or missing cached analysis must fall back to selection")
        model.project?.progressState="待纠正";model.restoringTracking=true
        XCTAssertFalse(model.showsPreviewSettings)
    }
    @MainActor func testEarlyExitPreservesHistoryStatusAndPendingReviewFile() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=ProjectStore(directory:root)
        try await store.prepare()
        let model=AppModel(store:store);model.startDemo()
        model.project?.isDemo=false
        model.project?.progressState="已分析 · 可预览"
        let project=try XCTUnwrap(model.project)
        let reviewURL=root.appendingPathComponent("review-\(project.id).json")
        let pending=Data("pending review sentinel".utf8)
        try pending.write(to:reviewURL)
        model.restoringTracking=true
        let time=model.currentTime, target=model.project?.target
        model.scrub(to:20)
        model.selectTarget(.init(x:0.1,y:0.1,width:0.3,height:0.6))
        XCTAssertEqual(model.currentTime,time)
        XCTAssertEqual(model.project?.target,target)
        model.goHome()
        XCTAssertEqual(model.project?.progressState,"已分析 · 可预览")
        for _ in 0..<200 {
            if model.projects.contains(where:{$0.id==project.id}) {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        let saved=try await store.projects()
        XCTAssertEqual(saved.first?.progressState,"已分析 · 可预览")
        XCTAssertEqual(try Data(contentsOf:reviewURL),pending)
        XCTAssertEqual(model.route,.home)
        XCTAssertFalse(model.restoringTracking)
    }
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
