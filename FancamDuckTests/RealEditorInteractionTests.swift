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

    func testPersistedAnalysisSettingsAndGenerationWithDesktopVideo() async throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_REAL_EDITOR_VALIDATION"] == "1" else {throw XCTSkip("Opt-in real desktop video workflow")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("RealWorkflow-"+UUID().uuidString)
        let store=ProjectStore(directory:directory),pipeline=CoreMLTrackingPipeline()
        let source=try await store.importFile(try TestVideoFixture.people())
        defer {try? FileManager.default.removeItem(at:directory)}
        let metadata=try await MediaService.shared.metadata(url:source)
        let people=try await pipeline.detections(source:source,time:0,region:nil)
        let selected=try XCTUnwrap(people.filter {$0.confidence>0.5}.min {$0.body.center.x<$1.body.center.x})
        var project=VideoProject(title:"Desktop real workflow",sourceFileName:source.lastPathComponent,metadata:metadata,settings:.init())
        project.target=selected.body;project.settings.end=metadata.duration
        project.settings.redaction.allOthers=true
        project.settings.resolution = .init(width:180,height:320)
        try await store.save(project)
        let model=AppModel(store:store,pipeline:pipeline)
        defer {model.goHome()}
        model.open(project);try await waitUntil {!model.restoringTracking && !model.detecting}
        XCTAssertTrue(model.canConfirm)
        model.advanceWorkflow()
        try await waitUntil {model.hasCompletedTracking && model.phase == .editing || model.errorMessage != nil || model.phase.issue != nil}
        XCTAssertNil(model.errorMessage);XCTAssertNil(model.phase.issue)
        XCTAssertTrue(model.hasCompletedTracking);XCTAssertEqual(model.route,.editor);XCTAssertNil(model.outputURL)
        let analyzed=try XCTUnwrap(model.project)
        let savedPeople=try await store.people(for:analyzed)
        XCTAssertFalse(try XCTUnwrap(savedPeople).isEmpty)
        let measuredAnalysis=await pipeline.performanceMetrics()
        let firstMetrics=try XCTUnwrap(measuredAnalysis)

        // A fresh actor must restore crowd observations, not infer them again for settings.
        model.goHome()
        let restoredPipeline=CoreMLTrackingPipeline()
        let restored=AppModel(store:store,pipeline:restoredPipeline)
        defer {restored.goHome()}
        restored.open(analyzed);try await waitUntil {!restored.restoringTracking}
        XCTAssertTrue(restored.hasCompletedTracking)
        restored.beginComposition();try await waitUntil {!restored.compositionBusy}
        restored.setCompositionAspect(.square);try await waitUntil {!restored.compositionBusy}
        let composedCrop=restored.compositionCrop,composedSettings=restored.project?.settings
        restored.finishComposition(commit:true,refreshDetections:false)
        restored.beginRedaction();try await waitUntil {!restored.compositionBusy}
        XCTAssertEqual(restored.compositionCrop,composedCrop)
        XCTAssertEqual(restored.project?.settings,composedSettings)
        restored.setRedactionRegion(.face);restored.setRedactionStyle(.image)
        XCTAssertEqual(restored.compositionCrop,composedCrop)
        restored.finishRedaction(commit:true)
        XCTAssertNotNil(restored.project?.settings.redaction.imageData)
        restored.project?.settings.resolution = .init(width:180,height:180)
        restored.advanceWorkflow()
        try await waitUntil {restored.outputURL != nil || restored.errorMessage != nil || restored.phase.issue != nil}
        XCTAssertNil(restored.errorMessage);XCTAssertNil(restored.phase.issue)
        let firstOutput=try XCTUnwrap(restored.outputURL)
        XCTAssertEqual(restored.route,.editor)
        let generated=try await MediaService.shared.metadata(url:firstOutput)
        XCTAssertEqual(generated.duration,metadata.duration,accuracy:0.12)
        XCTAssertEqual(generated.width,180);XCTAssertEqual(generated.height,180)
        let measuredGeneration=await restoredPipeline.performanceMetrics()
        let generatedMetrics=try XCTUnwrap(measuredGeneration)
        XCTAssertEqual(generatedMetrics.poseCalls,0,"Changing settings after reopen must reuse stored people")

        restored.backToEditor()
        restored.beginRedaction();restored.setRedactionStyle(.mosaic);restored.finishRedaction(commit:true)
        restored.advanceWorkflow()
        XCTAssertEqual(restored.outputURL,firstOutput,"Keep the old file during regeneration")
        try await waitUntil {restored.outputURL != firstOutput || restored.errorMessage != nil || restored.phase.issue != nil}
        XCTAssertNil(restored.errorMessage);XCTAssertNil(restored.phase.issue)
        XCTAssertNotEqual(restored.outputURL,firstOutput)
        let measuredFinal=await restoredPipeline.performanceMetrics()
        let finalMetrics=try XCTUnwrap(measuredFinal)
        XCTAssertEqual(finalMetrics.poseCalls,0)
        XCTAssertTrue(restored.hasReusableOutput)
        if let path=ProcessInfo.processInfo.environment["FANCAM_DUCK_VALIDATION_OUTPUT"] {
            let folder=URL(fileURLWithPath:path,isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let destination=folder.appendingPathComponent("verified-output.mp4")
            if FileManager.default.fileExists(atPath:destination.path) {try FileManager.default.removeItem(at:destination)}
            try FileManager.default.copyItem(at:try XCTUnwrap(restored.outputURL),to:destination)
            let evidence:[String:Any]=["duration":metadata.duration,"sourceWidth":metadata.width,"sourceHeight":metadata.height,"samples":restored.targetSamples.count,"analysisPoseCalls":firstMetrics.poseCalls,"restoredPoseCalls":finalMetrics.poseCalls,"outputWidth":180,"outputHeight":180]
            try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("result.json"),options:.atomic)
        }
        print("REAL_WORKFLOW duration=\(metadata.duration) samples=\(restored.targetSamples.count) analysisPoseCalls=\(firstMetrics.poseCalls) restoredPoseCalls=\(finalMetrics.poseCalls) output=180x180")
    }

    private func waitUntil(_ condition:() -> Bool) async throws {
        for _ in 0..<60000 {
            if condition() {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw NSError(domain:"RealEditorValidation",code:1,userInfo:[NSLocalizedDescriptionKey:"Timed out waiting for production editor state"])
    }
}
