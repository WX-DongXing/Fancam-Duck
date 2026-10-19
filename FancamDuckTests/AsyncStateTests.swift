import XCTest
import AVFoundation
@testable import FancamDuck

private actor ReviewGate {
    private var opened=false
    private var continuations:[CheckedContinuation<Void,Never>]=[]
    var waiting:Int { continuations.count }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() { opened=true;let pending=continuations;continuations=[];pending.forEach {$0.resume()} }
}
private actor ReviewTracker:TargetTracking {
    let detectionGate:ReviewGate?
    let analysisGate:ReviewGate?
    let deferredFailure:Bool
    private(set) var analyses=0
    private(set) var active=0
    private(set) var peak=0
    private(set) var discards=0
    private(set) var detectionsFinished=0
    private(set) var detectionsStarted=0
    init(detectionGate:ReviewGate?=nil,analysisGate:ReviewGate?=nil,deferredFailure:Bool=false) {
        self.detectionGate=detectionGate;self.analysisGate=analysisGate;self.deferredFailure=deferredFailure
    }
    func detections(source:URL,time:Double,region:NormalizedRect?) async throws -> [PersonObservation] {
        detectionsStarted+=1
        if let detectionGate { await detectionGate.wait() }
        detectionsFinished+=1
        return [.init(id:1,body:.init(x:0.3,y:0.2,width:0.2,height:0.6),confidence:0.9,embedding:[1,0])]
    }
    func analyze(source:URL,project:VideoProject,onUpdate:@escaping @Sendable (TrackingUpdate) async -> Void) async throws -> TrackingResult {
        analyses+=1;active+=1;peak=max(peak,active)
        if let analysisGate { await analysisGate.wait() }
        let body=project.target!
        var samples:[TargetSample]=[]
        var time=project.settings.start
        while time<project.settings.end-0.001 { samples.append(.init(time:time,body:body));time+=0.1 }
        samples.append(.init(time:project.settings.end,body:body))
        // Intentionally ignore cancellation, as a delayed framework callback can do.
        await onUpdate(.init(sample:samples.last!,progress:1))
        active-=1
        if deferredFailure,analyses == 1 {
            return .init(samples:samples.filter {$0.time<0.2},issue:.init(time:0.2,message:"回补失败",checkpoint:0.999,requiresManualSelection:true))
        }
        return .init(samples:samples,issue:nil)
    }
    func discard(projectID:UUID) { discards+=1 }
}
private enum ReviewFailure:Error { case export }
private actor ReviewExporter:VideoExporting {
    let previewGate:ReviewGate?
    let exportGate:ReviewGate?
    let failsExport:Bool
    private(set) var previewsFinished=0
    private(set) var exportsFinished=0
    init(previewGate:ReviewGate?=nil,exportGate:ReviewGate?=nil,failsExport:Bool=false) {
        self.previewGate=previewGate;self.exportGate=exportGate;self.failsExport=failsExport
    }
    @MainActor func preview(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> AVPlayerItem {
        if let previewGate { await previewGate.wait() }
        await finishedPreview()
        return AVPlayerItem(url:source)
    }
    private func finishedPreview() { previewsFinished+=1 }
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> URL {
        if let exportGate { await exportGate.wait() }
        exportsFinished+=1
        if failsExport { throw ReviewFailure.export }
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        try Data().write(to:file);return file
    }
}

@MainActor final class AsyncStateTests:XCTestCase {
    private var directory:URL!
    private var store:ProjectStore!
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store=ProjectStore(directory:directory)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at:directory) }
    private func project() async throws -> VideoProject {
        let fixture=try TestVideoFixture.people()
        let source=try await store.importFile(fixture)
        var p=VideoProject(title:"State regression",sourceFileName:source.lastPathComponent,metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        p.settings.end=0.7;p.settings.resolution = .init(width:180,height:320)
        try await store.save(p);return p
    }
    private func waitUntil(_ condition:() async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Expected asynchronous checkpoint was not reached")
    }
    private func selected(_ model:AppModel,_ p:VideoProject) async throws {
        model.open(p)
        try await waitUntil {!model.observations.isEmpty}
        model.selectTarget(try XCTUnwrap(model.observations.first).body)
    }
    func testCancelledDetectionDoesNotLeaveDemoDetectingOrApplyOldPeople() async throws {
        let gate=ReviewGate()
        let delayed=ReviewTracker(detectionGate:gate)
        let model=AppModel(store:store,pipeline:delayed)
        model.open(try await project())
        try await waitUntil {await gate.waiting==1}
        model.startDemo();await gate.release()
        try await waitUntil {await delayed.detectionsFinished==1}
        XCTAssertFalse(model.detecting);XCTAssertTrue(model.observations.isEmpty);XCTAssertNil(model.errorMessage)
        model.selectTarget(.init(x:0.3,y:0.2,width:0.2,height:0.6));XCTAssertTrue(model.canConfirm)
    }
    func testDetectionAtOldFrameReleasesBusyState() async throws {
        let gate=ReviewGate()
        let delayed=ReviewTracker(detectionGate:gate)
        let model=AppModel(store:store,pipeline:delayed)
        model.open(try await project())
        try await waitUntil {await gate.waiting>0}
        model.currentTime=0.3
        await gate.release()
        try await waitUntil {await delayed.detectionsFinished>0}
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertFalse(model.detecting,"A stale frame must not leave the editor busy")
        XCTAssertTrue(model.observations.isEmpty)
        model.goHome()
    }
    func testCompositionCanOpenAndCancelWhileDetectionIsPending() async throws {
        let gate=ReviewGate()
        let delayed=ReviewTracker(detectionGate:gate)
        let model=AppModel(store:store,pipeline:delayed)
        var p=try await project();p.target = .init(x:0.3,y:0.2,width:0.2,height:0.6)
        model.open(p)
        try await waitUntil {let waiting=await gate.waiting;return !model.restoringTracking && waiting>0}
        XCTAssertNotNil(model.editorActivityText)
        model.beginComposition()
        XCTAssertTrue(model.compositionEditing)
        XCTAssertFalse(model.detecting)
        XCTAssertTrue(model.compositionBusy)
        model.finishComposition(commit:false)
        XCTAssertFalse(model.compositionEditing)
        XCTAssertFalse(model.compositionBusy)
        await gate.release()
        try await waitUntil {await delayed.detectionsFinished>0}
        XCTAssertTrue(model.observations.isEmpty,"Late detection must not reopen cancelled settings")
        model.goHome()
    }
    func testUnresolvedDeferredFrameOpensManualSelectionBeforeAnalysisCanComplete() async throws {
        try await store.prepare()
        let source=directory.appendingPathComponent("source.mp4");try Data([0,1,2]).write(to:source)
        var p=VideoProject(title:"Deferred correction",sourceFileName:source.lastPathComponent,
            metadata:.init(width:1280,height:720,duration:1,frameRate:30),settings:.init())
        p.settings.end=0.7
        let tracker=ReviewTracker(deferredFailure:true),model=AppModel(store:store,pipeline:tracker)
        defer {model.goHome()}
        model.open(p);try await waitUntil {!model.detecting && !model.restoringTracking}
        model.selectTarget(.init(x:0.3,y:0.2,width:0.2,height:0.6));model.advanceWorkflow()
        try await waitUntil {model.manualSelection}
        XCTAssertEqual(model.currentTime,0.2,accuracy:0.001)
        XCTAssertFalse(model.hasCompletedTracking);XCTAssertFalse(model.canConfirm)
        XCTAssertNil(model.outputURL)
        let corrected=NormalizedRect(x:0.25,y:0.15,width:0.25,height:0.7)
        model.finishManualBox(corrected)
        XCTAssertFalse(model.manualSelection);XCTAssertTrue(model.canConfirm)
        model.confirmProcessing();try await waitUntil {model.hasCompletedTracking}
        XCTAssertEqual(model.phase,.editing);XCTAssertEqual(model.project?.target,corrected)
    }
    func testManualBoxDirectlySetsTargetWithoutDetectionAndIgnoresLateCandidates() async throws {
        try await store.prepare()
        let source=directory.appendingPathComponent("source.mp4")
        try Data([0,1,2]).write(to:source)
        var p=VideoProject(title:"Manual anchor",sourceFileName:source.lastPathComponent,
            metadata:.init(width:1280,height:720,duration:1,frameRate:30),settings:.init())
        p.settings.end=0.7
        let gate=ReviewGate(),tracker=ReviewTracker(detectionGate:gate)
        let model=AppModel(store:store,pipeline:tracker)
        defer {model.goHome()}
        model.open(p);try await waitUntil {await gate.waiting>0}
        model.beginManualSelection()
        let manual=NormalizedRect(x:0.1,y:0.12,width:0.3,height:0.7)
        model.finishManualBox(manual)
        XCTAssertEqual(model.project?.target,manual)
        XCTAssertFalse(model.manualSelection);XCTAssertFalse(model.detecting)
        XCTAssertTrue(model.canConfirm)
        await gate.release();try await waitUntil {await tracker.detectionsFinished == 1}
        try await Task.sleep(for:.milliseconds(30))
        let detectionCount=await tracker.detectionsStarted
        XCTAssertEqual(detectionCount,1,"Manual confirmation must not request a second detection")
        XCTAssertTrue(model.observations.isEmpty)
        XCTAssertEqual(model.project?.target,manual,"Late candidates must not replace the manual box")
        model.advanceWorkflow();try await waitUntil {model.hasCompletedTracking}
        XCTAssertEqual(model.phase,.editing)
        XCTAssertEqual(model.project?.target,manual)
        let analyses=await tracker.analyses;XCTAssertEqual(analyses,1)
    }
    func testManualSelectionSurvivesLateDetection() async throws {
        let gate=ReviewGate()
        let tracker=ReviewTracker(detectionGate:gate)
        let model=AppModel(store:store,pipeline:tracker)
        model.open(try await project())
        try await waitUntil {await gate.waiting>0}
        model.beginManualSelection()
        XCTAssertFalse(model.detecting)
        await gate.release()
        try await waitUntil {await tracker.detectionsFinished>0}
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertTrue(model.manualSelection,"Late candidates must not dismiss the drawing tool")
        XCTAssertTrue(model.observations.isEmpty)
        model.goHome()
    }
    func testFinishingCancelledPreviewCannotNavigateAwayFromHome() async throws {
        let gate=ReviewGate(),exporter=ReviewExporter(previewGate:gate)
        let model=AppModel(store:store,pipeline:ReviewTracker(),exporter:exporter)
        try await selected(model,try await project());model.confirmProcessing()
        try await waitUntil {await gate.waiting==1}
        model.goHome();await gate.release()
        try await waitUntil {await exporter.previewsFinished==1}
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.route,.home);XCTAssertNil(model.previewPlayer);XCTAssertNil(model.errorMessage)
    }
    func testReturnFromPausePreservesEditsAndIgnoresLateAnalysis() async throws {
        let gate=ReviewGate(),tracker=ReviewTracker(analysisGate:gate)
        let model=AppModel(store:store,pipeline:tracker,exporter:ReviewExporter())
        try await selected(model,try await project())
        let target=model.project?.target,settings=model.project?.settings
        model.confirmProcessing();try await waitUntil {await gate.waiting==1}
        model.pause();model.returnToEditingFromPause()
        XCTAssertEqual(model.route,.editor);XCTAssertEqual(model.phase,.editing)
        XCTAssertTrue(model.settingsEnabled);XCTAssertEqual(model.project?.target,target)
        XCTAssertEqual(model.project?.settings,settings)
        XCTAssertNil(model.processingPreview);XCTAssertFalse(model.hasCompletedTracking)
        model.updateRange(end:0.6)
        await gate.release();try await waitUntil {await tracker.active==0}
        for _ in 0..<5 {await Task.yield()}
        XCTAssertEqual(model.route,.editor);XCTAssertEqual(model.phase,.editing)
        XCTAssertEqual(model.project?.settings.end,0.6)
        try await waitUntil {!model.detecting}
        XCTAssertTrue(model.canConfirm)
        model.confirmProcessing();try await waitUntil {model.route == .export}
        let calls=await tracker.analyses
        XCTAssertEqual(calls,2);XCTAssertEqual(model.targetSamples.last?.time,0.6)
        XCTAssertNil(model.errorMessage);model.goHome()
    }
    func testBlockedRecoveryDoesNotPlayOrScrubPastConfirmationFrame() {
        let model=AppModel();model.startDemo()
        defer {model.goHome()}
        model.selectTarget(.init(x:0.3,y:0.1,width:0.2,height:0.7))
        model.currentTime=22.4
        model.phase = .blocked(.init(time:22.4,message:"Confirm identity",checkpoint:0.5))
        model.targetExplicitlySelected=false
        model.togglePreview()
        XCTAssertFalse(model.isPlaying,"Recovery must stay paused until identity is confirmed")
        model.pausePreview(refresh:false)
        model.scrub(to:30)
        XCTAssertEqual(model.currentTime,22.4,"The ordinary timeline is unavailable during recovery")
        model.seek(to:22.6)
        XCTAssertEqual(model.currentTime,22.6,"Explicit recovery frame navigation remains available")
    }
    func testImmediateResumeWaitsForCancelledAnalysisAndKeepsCheckpoint() async throws {
        let gate=ReviewGate(),tracker=ReviewTracker(analysisGate:gate)
        let model=AppModel(store:store,pipeline:tracker,exporter:ReviewExporter())
        try await selected(model,try await project());model.confirmProcessing()
        try await waitUntil {await gate.waiting==1}
        model.pause();model.resume()
        try await Task.sleep(for:.milliseconds(30))
        let calls=await tracker.analyses
        XCTAssertEqual(calls,1,"A second run must wait until cancellation has finished")
        await gate.release()
        try await waitUntil {model.route == .export}
        let peak=await tracker.peak,discards=await tracker.discards
        XCTAssertEqual(peak,1);XCTAssertEqual(discards,1,"Pause/resume must not discard the saved checkpoint")
        model.goHome()
    }
    func testCancelledExportErrorCannotRestoreReadyStateInEditor() async throws {
        let gate=ReviewGate(),exporter=ReviewExporter(exportGate:gate,failsExport:true)
        let model=AppModel(store:store,pipeline:ReviewTracker(),exporter:exporter)
        try await selected(model,try await project());model.confirmProcessing()
        try await waitUntil {model.route == .export}
        model.export();try await waitUntil {await gate.waiting==1}
        model.backToEditor();await gate.release()
        try await waitUntil {await exporter.exportsFinished==1}
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.route,.editor);XCTAssertEqual(model.phase,.editing);XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.targetSamples.isEmpty,"Cancelling export must preserve completed analysis")
        model.goHome()
    }
    func testFailedExportRestoresPreviewAfterReleasingPlayerResources() async throws {
        let exporter=ReviewExporter(failsExport:true)
        let model=AppModel(store:store,pipeline:ReviewTracker(),exporter:exporter)
        try await selected(model,try await project());model.confirmProcessing()
        try await waitUntil {model.route == .export}
        XCTAssertNotNil(model.previewPlayer)
        model.export();XCTAssertNil(model.previewPlayer)
        try await waitUntil {model.phase == .readyToExport}
        XCTAssertNotNil(model.previewPlayer);XCTAssertNotNil(model.errorMessage)
        model.goHome()
    }
    func testDeleteWaitsForPendingSavesAndBackgroundingCannotResurrectProject() async throws {
        let p=try await project(),model=AppModel(store:store,pipeline:ReviewTracker())
        model.open(p)
        for i in 0..<10 { model.project?.title="Save \(i)";model.persist() }
        model.goHome();await model.delete(p);model.suspend()
        try await Task.sleep(for:.milliseconds(40))
        let remaining=try await store.projects()
        XCTAssertTrue(remaining.isEmpty);XCTAssertNil(model.project)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.sourceURL(for:p)!.path))
    }
    func testCancelledImportDoesNotCreateProject() async throws {
        let fixture=try TestVideoFixture.people()
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        try FileManager.default.copyItem(at:fixture,to:temporary)
        let model=AppModel(store:store,pipeline:ReviewTracker())
        let task=Task {await model.importMovie(.init(url:temporary))};task.cancel();await task.value
        XCTAssertEqual(model.route,.home);XCTAssertNil(model.errorMessage);XCTAssertFalse(model.importing)
        let records=try await store.projects();XCTAssertTrue(records.isEmpty)
    }
    func testReferenceFrameStaysInTrimmedRangeAndReopensAtSavedAnchor() async throws {
        var p=try await project();p.target = .init(x:0.3,y:0.2,width:0.2,height:0.6);p.targetTime=0.4;p.settings.end=1.5
        let model=AppModel(store:store,pipeline:ReviewTracker())
        model.open(p);try await waitUntil {!model.restoringTracking};XCTAssertEqual(model.currentTime,0.4,accuracy:0.001)
        model.updateRange(start:0.5);XCTAssertNil(model.project?.target)
        model.seek(to:-10);XCTAssertEqual(model.currentTime,0.5,accuracy:0.001)
        model.seek(to:10);XCTAssertEqual(model.currentTime,1.5,accuracy:0.001)
        model.goHome()
    }
    func testCommittingBothTrimEdgesCanMoveBeyondTheOldEnd() async throws {
        var p = try await project(); p.settings.start = 0.1; p.settings.end = 0.7
        let model = AppModel(store: store, pipeline: ReviewTracker())
        model.open(p); try await waitUntil { !model.restoringTracking && !model.detecting }
        model.updateRange(start: 0.9, end: 1.5)
        XCTAssertEqual(model.project?.settings.start ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(model.project?.settings.end ?? 0, 1.5, accuracy: 0.001)
        model.goHome()
    }
    func testDraftTrimPreviewsOutsideSavedRangeWithoutMutatingIt() async throws {
        var p = try await project(); p.settings.start = 0.1; p.settings.end = 0.7
        let model = AppModel(store: store, pipeline: ReviewTracker())
        model.open(p); try await waitUntil { !model.restoringTracking && !model.detecting }
        model.scrub(to: 1.1, within: 0...p.metadata.duration)
        XCTAssertEqual(model.currentTime, 1.1, accuracy: 0.001)
        XCTAssertEqual(model.project?.settings.start, 0.1)
        XCTAssertEqual(model.project?.settings.end, 0.7)
        model.finishScrubbing(within: 0...p.metadata.duration)
        XCTAssertEqual(model.currentTime, 1.1, accuracy: 0.001)
        model.seek(to: 0.1); model.goHome()
    }
    func testBackgroundingStopsPreviewClock() async throws {
        let model=AppModel();model.startDemo();model.togglePreview();XCTAssertTrue(model.isPlaying)
        model.suspend();let time=model.currentTime
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertFalse(model.isPlaying);XCTAssertEqual(model.currentTime,time)
    }
}
