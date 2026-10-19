import XCTest
import AVFoundation
@testable import FancamDuck

/// Opt-in desktop footage with the production detector, tracker, store and exporter.
@MainActor final class RealEditorInteractionTests:XCTestCase {
    func testRealVideoDetectionDoesNotBlockSettingsAndRegeneration() async throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_REAL_EDITOR_VALIDATION"] == "1" else {
            throw XCTSkip("Opt-in real desktop video interaction validation")
        }
        let input=try TestVideoFixture.people()
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("RealEditor-"+UUID().uuidString)
        let store=ProjectStore(directory:directory),pipeline=CoreMLTrackingPipeline()
        let source=try await store.importFile(input)
        defer {try? FileManager.default.removeItem(at:directory)}
        let metadata=try await MediaService.shared.metadata(url:source)
        let people=try await pipeline.detections(source:source,time:0,region:nil)
        let person=try XCTUnwrap(people.filter {$0.confidence>0.5}.min {$0.body.center.x<$1.body.center.x})
        var project=VideoProject(title:"Real editor validation",sourceFileName:source.lastPathComponent,metadata:metadata,settings:.init())
        project.target=person.body;project.targetTime=0
        project.settings.end=metadata.duration
        project.settings.resolution = .init(width:180,height:320)
        try await store.save(project)
        let model=AppModel(store:store,pipeline:pipeline)
        defer {model.goHome()}
        model.open(project)
        try await waitUntil {!model.restoringTracking}
        XCTAssertFalse(model.isDemo)

        model.detectPeople()
        XCTAssertTrue(model.detecting)
        model.beginComposition()
        XCTAssertTrue(model.compositionEditing)
        XCTAssertFalse(model.detecting)
        try await waitUntil {!model.compositionBusy}
        model.setCompositionAspect(.square)
        try await waitUntil {!model.compositionBusy}
        XCTAssertEqual(model.project?.settings.aspectRatio,.square)
        model.finishComposition(commit:false)
        XCTAssertFalse(model.compositionEditing)
        XCTAssertEqual(model.project?.settings.aspectRatio,project.settings.aspectRatio)

        model.detectPeople()
        model.beginRedaction()
        XCTAssertTrue(model.redactionEditing)
        model.setRedactionRegion(.person)
        XCTAssertEqual(model.project?.settings.redaction.region,.person)
        model.finishRedaction(commit:false)
        XCTAssertEqual(model.project?.settings.redaction,project.settings.redaction)

        model.detectPeople()
        model.beginManualSelection()
        XCTAssertTrue(model.manualSelection)
        XCTAssertFalse(model.detecting)
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertTrue(model.manualSelection)
        model.manualSelection=false
        model.detectPeople()
        try await waitUntil {!model.detecting && !model.observations.isEmpty}
        XCTAssertNil(model.errorMessage)

        model.confirmProcessing()
        try await waitUntil {model.route == .export || model.errorMessage != nil || model.phase.issue != nil}
        XCTAssertNil(model.errorMessage);XCTAssertNil(model.phase.issue)
        guard model.route == .export else {return}
        model.export()
        try await waitUntil {model.outputURL != nil || model.errorMessage != nil}
        XCTAssertNil(model.errorMessage)
        let first=try XCTUnwrap(model.outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath:first.path))

        model.backToEditor()
        try await waitUntil {!model.detecting}
        model.beginRedaction();model.setRedactionRegion(.face);model.setRedactionStyle(.mosaic)
        model.finishRedaction(commit:true)
        XCTAssertTrue(model.needsRegeneration)
        model.confirmProcessing()
        try await waitUntil {model.route == .export || model.errorMessage != nil || model.phase.issue != nil}
        XCTAssertNil(model.errorMessage);XCTAssertNil(model.phase.issue)
        let output=try XCTUnwrap(model.outputURL)
        let actual=try await MediaService.shared.metadata(url:output)
        XCTAssertEqual(actual.duration,project.settings.end,accuracy:0.1)
        XCTAssertTrue(model.project?.redactionPlan?.covers(model.project!) == true)
        XCTAssertEqual(model.project?.settings.redaction.style,.mosaic)
        XCTAssertFalse(model.detecting);XCTAssertFalse(model.compositionBusy)
    }

    private func waitUntil(_ condition:() -> Bool) async throws {
        for _ in 0..<12000 {
            if condition() {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw NSError(domain:"RealEditorValidation",code:1,userInfo:[NSLocalizedDescriptionKey:"Timed out waiting for production editor state"])
    }
}
