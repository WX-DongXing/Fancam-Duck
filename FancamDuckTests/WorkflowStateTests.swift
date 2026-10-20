import XCTest
import AVFoundation
@testable import FancamDuck

private actor WorkflowTracker:TargetTracking {
    private(set) var analyses=0
    private(set) var restored=0
    private let body=NormalizedRect(x:0.3,y:0.2,width:0.2,height:0.6)
    func detections(source:URL,time:Double,region:NormalizedRect?) -> [PersonObservation] {[.init(id:1,body:body,confidence:1)]}
    func analyze(source:URL,project:VideoProject,onUpdate:@escaping @Sendable (TrackingUpdate) async -> Void) -> TrackingResult {
        analyses+=1
        return .init(samples:(0...10).map {.init(time:Double($0)/10,body:body)},issue:nil)
    }
    func cachedPeople(source:URL) -> [Int:DetectionBatch] {[0:.init(primary:[.init(id:1,body:body,confidence:1)],relaxed:[])]}
    func restorePeople(_ batches:[Int:DetectionBatch],source:URL) {restored=batches.count}
}
private actor WorkflowExporter:VideoExporting {
    private(set) var exports=0
    private(set) var renderedSettings:EditSettings?
    private var hold=false
    private var continuation:CheckedContinuation<Void,Never>?
    var waiting:Bool {continuation != nil}
    func holdNext() {hold=true}
    func release() {continuation?.resume();continuation=nil}
    @MainActor func preview(source:URL,project:VideoProject,samples:[TargetSample]) -> AVPlayerItem {AVPlayerItem(url:source)}
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample],onProgress:@escaping @Sendable (Double) async -> Void) async throws -> URL {
        await onProgress(0)
        await onProgress(0.1)
        return try await exportMovingCrop(source:source,project:project,samples:samples)
    }
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> URL {
        exports+=1;renderedSettings=project.settings
        if hold {hold=false;await withCheckedContinuation {continuation=$0}}
        let output=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        try FileManager.default.copyItem(at:source,to:output);return output
    }
}
@MainActor final class WorkflowStateTests:XCTestCase {
    func testAnalysisStopsBeforeGenerationAndSurvivesReopen() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=ProjectStore(directory:root);try await store.prepare()
        let source=root.appendingPathComponent("source.mp4");try Data([0,1,2]).write(to:source)
        var project=VideoProject(title:"Workflow state",sourceFileName:source.lastPathComponent,metadata:.init(width:1280,height:720,duration:1,frameRate:30),settings:.init())
        project.target = .init(x:0.3,y:0.2,width:0.2,height:0.6);project.settings.end=1
        try await store.save(project)
        let tracker=WorkflowTracker(),exporter=WorkflowExporter(),model=AppModel(store:store,pipeline:tracker,exporter:exporter)
        defer {model.goHome()}
        model.open(project);try await wait {!model.restoringTracking && !model.detecting}
        model.advanceWorkflow();try await wait {model.hasCompletedTracking && model.phase == .editing}
        XCTAssertEqual(model.route,.editor);XCTAssertNil(model.outputURL)
        let noExports=await exporter.exports;XCTAssertEqual(noExports,0)
        XCTAssertFalse(try XCTUnwrap(model.project).settings.redaction.enabled)
        model.beginComposition();try await wait {!model.compositionBusy}
        model.setCompositionAspect(.square);try await wait {!model.compositionBusy}
        model.compositionZoom(1.1);try await wait {!model.compositionBusy}
        let crop=model.compositionCrop,settings=model.project?.settings
        model.finishComposition(commit:true,refreshDetections:false)
        model.beginRedaction();XCTAssertEqual(model.compositionCrop,crop,"Switching tools must not flash the source frame");try await wait {!model.compositionBusy}
        XCTAssertTrue(model.compositionEditing)
        XCTAssertEqual(model.compositionCrop,crop)
        XCTAssertEqual(model.project?.settings,settings)
        XCTAssertFalse(try XCTUnwrap(model.project).settings.redaction.enabled)
        model.enableAutomaticRedaction()
        XCTAssertTrue(try XCTUnwrap(model.project).settings.redaction.enabled)
        XCTAssertEqual(model.compositionCrop,crop)
        model.clearRedactions();model.finishRedaction(commit:true)
        model.updateRange(start:0.2,end:0.8,previewTime:0.2)
        try await wait {!model.compositionBusy}
        XCTAssertTrue(model.hasCompletedTracking)
        XCTAssertEqual(model.currentTime,0.2,accuracy:0.001)
        XCTAssertEqual(model.project?.settings.end,0.8)
        let saved=try XCTUnwrap(model.project)
        model.goHome()
        let fresh=WorkflowTracker(),restored=AppModel(store:store,pipeline:fresh,exporter:exporter)
        defer {restored.goHome()}
        restored.open(saved);try await wait {!restored.restoringTracking && !restored.detecting}
        XCTAssertTrue(restored.hasCompletedTracking)
        let restoredBatches=await fresh.restored;XCTAssertEqual(restoredBatches,1)
        restored.beginComposition();try await wait {!restored.compositionBusy}
        let generationCrop=restored.compositionCrop
        let generationSettings=restored.project?.settings
        restored.advanceWorkflow();try await wait {restored.outputURL != nil}
        XCTAssertEqual(restored.compositionCrop,generationCrop)
        let rendered=await exporter.renderedSettings
        XCTAssertEqual(rendered,generationSettings,"Generate must use the current composition settings")
        XCTAssertEqual(restored.route,.editor)
        let first=restored.outputURL
        restored.backToEditor();try await wait {!restored.detecting}
        restored.project?.settings.compositionScale=1.15
        restored.advanceWorkflow();XCTAssertEqual(restored.outputURL,first)
        try await wait {restored.outputURL != first}
        let analyses=await fresh.analyses,calls=await exporter.exports
        XCTAssertEqual(analyses,0);XCTAssertEqual(calls,2)
        XCTAssertTrue(restored.hasReusableOutput)
        let retained=restored.outputURL
        restored.backToEditor();try await wait {!restored.detecting}
        restored.project?.settings.compositionScale=1.2
        await exporter.holdNext();restored.advanceWorkflow()
        XCTAssertEqual(restored.phase.progress,0,"A fresh generation must start at zero")
        for _ in 0..<1000 {if await exporter.waiting {break};try await Task.sleep(for:.milliseconds(5))}
        let waiting=await exporter.waiting;XCTAssertTrue(waiting)
        XCTAssertEqual(restored.phase.progress,0.099,accuracy:0.001,"Cached analysis must not create a 75% jump")
        restored.cancelGeneration();XCTAssertEqual(restored.phase,.editing)
        await exporter.release();try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(restored.outputURL,retained)
        XCTAssertTrue(restored.hasCompletedTracking)
        XCTAssertEqual(restored.project?.settings.compositionScale,1.2)
        restored.beginComposition();try await wait {!restored.compositionBusy}
        restored.setCompositionAspect(.square)
        restored.goHome()
        XCTAssertEqual(restored.project?.settings.aspectRatio,.square,"Leaving during preview preparation must preserve immediate settings")

    }
    func testCompletedAnalysisClampsTrimToCachedBoundsAndRetainsComposition() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model=AppModel(store:ProjectStore(directory:root),pipeline:WorkflowTracker(),exporter:WorkflowExporter())
        model.startDemo();defer {model.goHome()}
        model.selectTarget(.init(x:0.3,y:0.2,width:0.2,height:0.6))
        model.project?.isDemo=false;model.project?.metadata = .init(width:1280,height:720,duration:2,frameRate:30)
        model.project?.targetTime=0.5
        model.project?.settings.start=0.2;model.project?.settings.end=1
        model.targetSamples=(2...10).map {.init(time:Double($0)/10,body:model.project!.target!)}
        model.hasCompletedTracking=true
        model.beginComposition();try await wait {!model.compositionBusy}
        let scale=model.project?.settings.compositionScale
        model.scrub(to:0.7,within:0.2...1,sourceOnly:true)
        XCTAssertTrue(model.compositionEditing)
        XCTAssertNotNil(model.compositionCrop)
        XCTAssertEqual(model.currentTime,0.7)
        model.updateRange(end:1.5,previewTime:1.5)
        XCTAssertTrue(model.hasCompletedTracking)
        XCTAssertTrue(model.compositionEditing)
        XCTAssertEqual(model.project?.settings.end,1)
        XCTAssertEqual(model.project?.settings.compositionScale,scale)
        XCTAssertTrue(model.canConfirm)
        model.updateRange(start:0,end:2)
        XCTAssertEqual(model.project?.settings.start,0.2)
        XCTAssertEqual(model.project?.settings.end,1)
        model.updateRange(start:0.3,end:0.9)
        XCTAssertEqual(model.project?.settings.start,0.3)
        XCTAssertEqual(model.project?.settings.end,0.9)
        XCTAssertEqual(model.trimBounds,0.2...1)
        model.updateRange(start:0.2,end:1)
        XCTAssertEqual(model.project?.settings.start,0.2)
        XCTAssertEqual(model.project?.settings.end,1)
        XCTAssertTrue(model.hasCompletedTracking,"Restoring the analyzed range must reuse analysis")
    }
    func testReselectDuringAnalysisClearsTargetAndRejectsOldDemoUpdates() async throws {
        let model=AppModel();model.startDemo();defer {model.goHome()}
        model.selectTarget(DemoStage.body(index:1,time:0));model.advanceWorkflow()
        XCTAssertNotEqual(model.phase,.editing)
        model.reselectAnalysisTarget()
        XCTAssertEqual(model.phase,.editing);XCTAssertEqual(model.route,.editor)
        XCTAssertNil(model.project?.target);XCTAssertNil(model.trackedSample)
        XCTAssertFalse(model.hasCompletedTracking);XCTAssertTrue(model.targetSamples.isEmpty)
        XCTAssertFalse(model.canConfirm)
        try await Task.sleep(for:.milliseconds(250))
        XCTAssertEqual(model.phase,.editing);XCTAssertNil(model.project?.target)
        XCTAssertEqual(model.currentTime,model.project!.settings.start)
        model.selectTarget(DemoStage.body(index:2,time:0))
        XCTAssertTrue(model.canConfirm)
    }
    func testRejectedSmallManualBoxKeepsDrawingStateAndRequiresValidConfirmation() {
        let model=AppModel();model.startDemo();defer {model.goHome()}
        model.beginManualSelection()
        XCTAssertFalse(model.finishManualBox(.init(x:0.2,y:0.2,width:0.01,height:0.02)))
        XCTAssertTrue(model.manualSelection);XCTAssertNil(model.project?.target)
        XCTAssertFalse(model.canConfirm)
        XCTAssertNotNil(model.detectionNotice)
        XCTAssertTrue(model.finishManualBox(.init(x:0.2,y:0.2,width:0.2,height:0.6)))
        XCTAssertFalse(model.manualSelection);XCTAssertTrue(model.canConfirm)
    }
    private func wait(line:UInt = #line,_ condition:()->Bool) async throws {
        for _ in 0..<1000 {if condition(){return};try await Task.sleep(for:.milliseconds(10))}
        XCTFail("Workflow did not reach expected state",line:line);throw CancellationError()
    }
}
