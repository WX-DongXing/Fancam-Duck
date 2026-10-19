import XCTest
import AVFoundation
@testable import FancamDuck

private actor ExportGate {
    private var continuation:CheckedContinuation<Void,Never>?
    func wait() async {await withCheckedContinuation {continuation=$0}}
    func release() {continuation?.resume();continuation=nil}
}
private actor DurableTracker:TargetTracking {
    private(set) var calls=0
    let body=NormalizedRect(x:0.3,y:0.2,width:0.15,height:0.5)
    func detections(source:URL,time:Double,region:NormalizedRect?) -> [PersonObservation] {[.init(id:1,body:body,confidence:0.9)]}
    func analyze(source:URL,project:VideoProject,onUpdate:@escaping @Sendable (TrackingUpdate) async -> Void) async throws -> TrackingResult {
        calls+=1;return .init(samples:(0...7).map {.init(time:Double($0)*0.1,body:body)},issue:nil)
    }
}
private actor DurableExporter:VideoExporting {
    let gate:ExportGate?
    private(set) var calls=0
    init(gate:ExportGate?=nil) {self.gate=gate}
    @MainActor func preview(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> AVPlayerItem {AVPlayerItem(url:source)}
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> URL {
        try await exportMovingCrop(source:source,project:project,samples:samples,onProgress:{_ in})
    }
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample],onProgress:@escaping @Sendable (Double) async -> Void) async throws -> URL {
        calls+=1;await onProgress(0.4)
        if let gate {await gate.wait();await onProgress(0.9)}
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        try FileManager.default.copyItem(at:source,to:file);return file
    }
}
@MainActor final class OptimizationRoundThreeTests:XCTestCase {
    private var root:URL!
    private var store:ProjectStore!
    override func setUp() async throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=ProjectStore(directory:root)}
    override func tearDown() async throws {try? FileManager.default.removeItem(at:root)}
    private func project() async throws -> VideoProject {
        let fixture=try TestVideoFixture.people(),source=try await store.importFile(fixture)
        var p=VideoProject(title:"Durable output",sourceFileName:source.lastPathComponent,metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        p.target = .init(x:0.3,y:0.2,width:0.15,height:0.5);p.settings.end=0.7;p.settings.resolution = .init(width:180,height:320)
        try await store.save(p);return p
    }
    private func wait(_ predicate:()->Bool) async throws {
        for _ in 0..<500 {if predicate(){return};try await Task.sleep(for:.milliseconds(10))}
        XCTFail("Round three async checkpoint timed out")
    }
    func testDurableOutputMatchesSettingsRetainsSavedStatusAndDeletesWithProject() async throws {
        let p=try await project(),source=try XCTUnwrap(store.sourceURL(for:p))
        let url=try await store.saveOutput(project:p,url:source)
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        try await store.markOutputSaved(project:p,url:url)
        let restored=try await ProjectStore(directory:root).output(for:p)
        XCTAssertEqual(restored?.url,url);XCTAssertEqual(restored?.savedToPhotos,true)
        var edited=p;edited.settings.compositionScale=1.2
        let mismatch=try await store.output(for:edited);XCTAssertNil(mismatch)
        try await store.remove(p)
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
    func testReopenedCompletedProjectDoesNotAnalyzeOrExportAgain() async throws {
        let p=try await project(),tracker=DurableTracker(),exporter=DurableExporter()
        let model=AppModel(store:store,pipeline:tracker,exporter:exporter)
        model.open(p);try await wait {!model.detecting && !model.restoringTracking}
        model.confirmProcessing();try await wait {model.route == .export}
        model.export();try await wait {model.outputURL != nil}
        let saved=try XCTUnwrap(model.project),file=try XCTUnwrap(model.outputURL)
        model.goHome();model.open(saved);try await wait {!model.detecting && !model.restoringTracking}
        XCTAssertTrue(model.hasReusableOutput);model.confirmProcessing()
        XCTAssertEqual(model.phase,.completed(file))
        let analyses=await tracker.calls,exports=await exporter.calls
        XCTAssertEqual(analyses,1);XCTAssertEqual(exports,1)
        model.goHome()
    }
    func testViewingCompositionWithoutEditsDoesNotInvalidateCompletedOutput() async throws {
        let p=try await project(),tracker=DurableTracker(),exporter=DurableExporter()
        let model=AppModel(store:store,pipeline:tracker,exporter:exporter)
        model.open(p);try await wait {!model.detecting && !model.restoringTracking}
        model.confirmProcessing();try await wait {model.route == .export}
        model.export();try await wait {model.outputURL != nil}
        model.backToEditor();try await wait {!model.detecting}
        let original=try XCTUnwrap(model.project?.settings)
        model.beginComposition();try await wait {!model.compositionBusy}
        model.finishComposition(commit:true)
        XCTAssertEqual(model.project?.settings,original)
        XCTAssertTrue(model.hasReusableOutput)
        model.confirmProcessing()
        let exports=await exporter.calls;XCTAssertEqual(exports,1)
        model.goHome()
    }
    func testEditedConfigurationStaysInEditorUntilNewFileIsGenerated() async throws {
        let p=try await project(),tracker=DurableTracker(),gate=ExportGate(),exporter=DurableExporter(gate:gate)
        let model=AppModel(store:store,pipeline:tracker,exporter:exporter)
        model.open(p);try await wait {!model.detecting && !model.restoringTracking}
        model.confirmProcessing();try await wait {model.route == .export}
        model.backToEditor();try await wait {!model.detecting}
        XCTAssertFalse(model.needsRegeneration)
        model.project?.settings.compositionScale=1.2
        XCTAssertTrue(model.needsRegeneration);XCTAssertFalse(model.hasReusableOutput)
        model.confirmProcessing()
        try await wait {model.phase.progress>0.75}
        XCTAssertEqual(model.route,.editor);XCTAssertNil(model.outputURL)
        await gate.release()
        try await wait {model.outputURL != nil}
        XCTAssertEqual(model.route,.export);XCTAssertFalse(model.needsRegeneration)
        XCTAssertTrue(model.hasReusableOutput)
        model.backToEditor();try await wait {!model.detecting}
        model.confirmProcessing()
        let calls=await exporter.calls,analyses=await tracker.calls
        XCTAssertEqual(calls,1);XCTAssertEqual(analyses,1)
        model.goHome()
    }
    func testCancellingRedactionSettingsKeepsOriginalGeneratedFileReusable() async throws {
        let p=try await project(),tracker=DurableTracker(),exporter=DurableExporter(),model=AppModel(store:store,pipeline:tracker,exporter:exporter)
        model.open(p);try await wait {!model.detecting && !model.restoringTracking}
        model.confirmProcessing();try await wait {model.route == .export}
        model.export();try await wait {model.outputURL != nil}
        let output=model.outputURL
        model.backToEditor();try await wait {!model.detecting}
        model.beginRedaction();model.setRedactionStyle(.mosaic)
        XCTAssertTrue(model.needsRegeneration);XCTAssertFalse(model.hasReusableOutput)
        model.finishRedaction(commit:false)
        XCTAssertFalse(model.needsRegeneration);XCTAssertTrue(model.hasReusableOutput)
        model.confirmProcessing();XCTAssertEqual(model.outputURL,output)
        let exports=await exporter.calls;XCTAssertEqual(exports,1)
        model.goHome()
    }
    func testActualRegenerationExportsEditedAspectAndResolutionInsteadOfOldFile() async throws {
        let p=try await project(),tracker=DurableTracker(),model=AppModel(store:store,pipeline:tracker,exporter:VideoExporter())
        model.open(p);try await wait {!model.detecting && !model.restoringTracking}
        model.confirmProcessing();try await wait {model.route == .export}
        model.export();try await wait {model.outputURL != nil}
        let old=try XCTUnwrap(model.outputURL)
        model.backToEditor();try await wait {!model.detecting}
        model.project?.settings.aspectRatio = .square;model.project?.settings.resolution = .init(width:200,height:200)
        XCTAssertTrue(model.needsRegeneration);XCTAssertFalse(model.hasReusableOutput)
        model.confirmProcessing();XCTAssertEqual(model.route,.editor)
        try await wait {model.outputURL != nil || model.errorMessage != nil}
        XCTAssertNil(model.errorMessage)
        let new=try XCTUnwrap(model.outputURL),metadata=try await MediaService.shared.metadata(url:new)
        XCTAssertNotEqual(new,old);XCTAssertEqual(metadata.width,200);XCTAssertEqual(metadata.height,200)
        let analyses=await tracker.calls;XCTAssertEqual(analyses,1)
        XCTAssertFalse(model.needsRegeneration);XCTAssertTrue(model.hasReusableOutput)
        model.goHome()
    }
    func testCancelExportRejectsLateProgressAndRetainsCompletedAnalysis() async throws {
        let p=try await project(),gate=ExportGate(),exporter=DurableExporter(gate:gate)
        let model=AppModel(store:store,pipeline:DurableTracker(),exporter:exporter)
        model.open(p);try await wait {!model.detecting && !model.restoringTracking}
        model.confirmProcessing();try await wait {model.route == .export}
        model.export();try await wait {model.exportProgress==0.4}
        model.cancelExport();XCTAssertTrue(model.cancellingExport)
        await gate.release();try await wait {model.phase == .readyToExport}
        XCTAssertEqual(model.exportProgress,0);XCTAssertNil(model.outputURL)
        XCTAssertTrue(model.hasCompletedTracking);XCTAssertNotNil(model.previewPlayer);XCTAssertNil(model.errorMessage)
        let output=try await store.output(for:p);XCTAssertNil(output)
        model.goHome()
    }
}
