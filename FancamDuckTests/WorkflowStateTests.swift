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
    private func wait(line:UInt = #line,_ condition:()->Bool) async throws {
        for _ in 0..<1000 {if condition(){return};try await Task.sleep(for:.milliseconds(10))}
        XCTFail("Workflow did not reach expected state",line:line);throw CancellationError()
    }
}
