import XCTest
import AVFoundation
@testable import FancamDuck

private actor SettingsPreviewGate {
    private var open=false
    private var continuations:[CheckedContinuation<Void,Never>]=[]
    var count:Int {continuations.count}
    func wait() async {if open{return};await withCheckedContinuation {continuations.append($0)}}
    func release() {open=true;continuations.forEach {$0.resume()};continuations=[]}
}
private struct DelayedSettingsExporter:VideoExporting {
    let gate:SettingsPreviewGate
    @MainActor func preview(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> AVPlayerItem {
        await gate.wait();return AVPlayerItem(url:source)
    }
    func exportMovingCrop(source:URL,project:VideoProject,samples:[TargetSample]) async throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        try Data([1]).write(to:url);return url
    }
}
final class ContinuousSettingsTests:XCTestCase {
    @MainActor func testRapidEditsAndToolSwitchKeepCropAndGenerationAvailable() async throws {
        let model=AppModel();model.startDemo()
        let box=DemoStage.body(index:1,time:0)
        model.selectTarget(box);model.hasCompletedTracking=true
        model.targetSamples=[.init(time:0,body:box),.init(time:58.2,body:box)]
        model.beginComposition()
        for _ in 0..<400 {if !model.compositionBusy {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertNotNil(model.compositionCrop)
        model.setCompositionAspect(.classic)
        XCTAssertTrue(model.compositionBusy);XCTAssertTrue(model.canConfirm)
        let before=try XCTUnwrap(model.compositionCrop)
        model.compositionZoom(1.1)
        XCTAssertLessThan(try XCTUnwrap(model.compositionCrop).height,before.height)
        let zoomed=model.compositionCrop
        model.beginRedaction();XCTAssertTrue(model.compositionEditing)
        XCTAssertEqual(model.compositionCrop,zoomed)
        model.finishRedaction(commit:true,keepComposition:true);model.beginComposition()
        XCTAssertEqual(model.compositionCrop,zoomed)
        XCTAssertTrue(model.compositionEditing);XCTAssertTrue(model.canConfirm)
        model.setFollowSpeed(.responsive);model.centerComposition(horizontal:true)
        XCTAssertEqual(model.project?.settings.followSpeed,.responsive)
        model.enableAutomaticRedaction();XCTAssertTrue(model.canConfirm)
        model.clearRedactions();XCTAssertTrue(model.canConfirm)
        XCTAssertTrue(model.compositionBusy,"Mask changes must still refresh the moving preview without locking editing")
        for _ in 0..<400 {if !model.compositionBusy {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(model.project?.settings.aspectRatio,.classic)
        let final=try XCTUnwrap(model.compositionCrop)
        XCTAssertEqual(final.width/final.height,0.75,accuracy:0.0001)
        model.goHome()
    }
    @MainActor func testGenerateDuringPreviewBuildSupersedesLatePreview() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory),gate=SettingsPreviewGate()
        try await store.prepare();try Data([1]).write(to:directory.appendingPathComponent("source.mp4"))
        let box=NormalizedRect(x:0.4,y:0.2,width:0.2,height:0.6)
        var project=VideoProject(title:"Pending preview",sourceFileName:"source.mp4",metadata:.init(width:1920,height:1080,duration:1,frameRate:30),settings:EditSettings())
        project.settings.end=1;project.target=box
        try await store.save(project)
        let model=AppModel(store:store,exporter:DelayedSettingsExporter(gate:gate))
        model.project=project;model.phase = .editing;model.route = .editor
        model.hasCompletedTracking=true;model.targetExplicitlySelected=true
        model.targetSamples=(0...6).map {.init(time:Double($0)/6,body:box)}
        model.beginComposition()
        for _ in 0..<400 {if await gate.count>0 {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(model.compositionBusy);XCTAssertTrue(model.canConfirm)
        model.advanceWorkflow()
        for _ in 0..<400 {if case .completed = model.phase {break};try await Task.sleep(for:.milliseconds(10))}
        guard case .completed = model.phase else {await gate.release();return XCTFail("Generation was blocked by preview")}
        await gate.release();try await Task.sleep(for:.milliseconds(50))
        XCTAssertFalse(model.compositionEditing)
        XCTAssertNotNil(model.outputURL)
        model.goHome()
    }
}
