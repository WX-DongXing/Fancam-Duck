import XCTest
import AVFoundation
@testable import FancamDuck

private actor RedactionReviewPipeline: TargetTracking {
    private(set) var analyses=0
    private(set) var redactionCalls=0
    func detections(source:URL,time:Double,region:NormalizedRect?) async throws -> [PersonObservation] {
        [.init(id:1,body:.init(x:0.2,y:0.15,width:0.2,height:0.7),confidence:0.9),
         .init(id:2,body:.init(x:0.6,y:0.15,width:0.2,height:0.7),confidence:0.9)]
    }
    func analyze(source:URL,project:VideoProject,onUpdate:@escaping @Sendable (TrackingUpdate) async -> Void) async throws -> TrackingResult {
        analyses+=1
        return .init(samples:(0...7).map {.init(time:Double($0)/10,body:project.target!)},issue:nil)
    }
    func redactions(source:URL,project:VideoProject,samples:[TargetSample],onProgress:@escaping @Sendable (Double) async -> Void) async throws -> RedactionAnalysisResult {
        if !project.settings.redaction.allOthers {return try await redactions(source:source,project:project,onProgress:onProgress)}
        redactionCalls+=1
        let people=try await detections(source:source,time:0,region:nil)
        let frames=(0...7).map {(Double($0)/10,DetectionBatch(primary:people,relaxed:[]))}
        return .init(plan:try AutomaticRedaction.build(frames:frames,project:project,samples:samples),issue:nil)
    }
    func redactions(source:URL,project:VideoProject,onProgress:@escaping @Sendable (Double) async -> Void) async throws -> RedactionAnalysisResult {
        redactionCalls+=1
        let subject=project.settings.redaction.subjects[0]
        if subject.anchors.count==1 {return .init(plan:nil,issue:.init(subjectID:subject.id,time:0.2,message:"Confirm mask identity"))}
        let track=RedactionTrack(subjectID:subject.id,frames:(0...7).map {.init(time:Double($0)/10,rect:subject.anchors.last!.body)})
        return .init(plan:.init(subjects:[subject],region:project.settings.redaction.region,start:0,end:0.7,tracks:[track]),issue:nil)
    }
}

@MainActor final class RedactionStateTests: XCTestCase {
    func testChangingRegionAppliesItsDefaultWithoutOverwritingUnchangedRegion() {
        let model=AppModel();model.startDemo();defer {model.goHome()}
        XCTAssertEqual(model.project?.settings.redaction.strength,0.8)
        model.setRedactionRegion(.person)
        XCTAssertEqual(model.project?.settings.redaction.strength,0.3)
        model.setRedactionStrength(0.45);model.setRedactionRegion(.person)
        XCTAssertEqual(model.project?.settings.redaction.strength,0.45)
        model.setRedactionRegion(.face)
        XCTAssertEqual(model.project?.settings.redaction.strength,0.8)
    }
    func testLegacyMaskProjectUpgradesToAllOthersAndProcessesWithoutReselecting() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory),pipeline=RedactionReviewPipeline()
        let fixture=try TestVideoFixture.people(),source=try await store.importFile(fixture)
        var project=VideoProject(title:"Automatic mask",sourceFileName:source.lastPathComponent,metadata:try await MediaService.shared.metadata(url:source),settings:.init())
        project.target = .init(x:0.2,y:0.15,width:0.2,height:0.7);project.settings.end=0.7;project.settings.resolution = .init(width:180,height:320)
        project.settings.redaction.subjects=[.init(anchors:[.init(time:0,body:.init(x:0.6,y:0.15,width:0.2,height:0.7))])]
        try await store.save(project)
        let model=AppModel(store:store,pipeline:pipeline);model.open(project)
        try await waitUntil {!model.detecting && !model.restoringTracking}
        XCTAssertTrue(model.project!.settings.redaction.allOthers)
        XCTAssertTrue(model.project!.settings.redaction.subjects.isEmpty)
        model.confirmProcessing()
        try await waitUntil {model.route == .export || model.errorMessage != nil}
        XCTAssertNil(model.errorMessage);XCTAssertNil(model.redactionIssue)
        XCTAssertEqual(model.project?.target,project.target)
        XCTAssertEqual(model.phase,.readyToExport)
        let analyses=await pipeline.analyses,calls=await pipeline.redactionCalls
        XCTAssertEqual(analyses,1);XCTAssertEqual(calls,1)
        XCTAssertTrue(model.project?.redactionPlan?.covers(model.project!.settings) == true)
        model.goHome()
    }
    func testChangingMasksAfterAnalysisKeepsCompositionUsableAndRebuildsMasksOnConfirm() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory),pipeline=RedactionReviewPipeline()
        let fixture=try TestVideoFixture.people()
        let source=try await store.importFile(fixture)
        var project=VideoProject(title:"Edit masks after analysis",sourceFileName:source.lastPathComponent,metadata:try await MediaService.shared.metadata(url:source),settings:.init())
        project.target = .init(x:0.2,y:0.15,width:0.2,height:0.7)
        project.settings.redaction.allOthers=true;project.settings.end=0.7;project.settings.resolution = .init(width:180,height:320)
        try await store.save(project)
        try await store.saveTrajectory(project:project,samples:(0...7).map {.init(time:Double($0)/10,body:project.target!)})
        let model=AppModel(store:store,pipeline:pipeline);model.open(project)
        defer {model.goHome()}
        try await waitUntil {!model.detecting && !model.restoringTracking}
        XCTAssertTrue(model.hasCompletedTracking)
        model.beginRedaction();model.setRedactionRegion(.person);model.finishRedaction(commit:true)
        XCTAssertNil(model.project?.redactionPlan)
        model.beginComposition();try await waitUntil {!model.compositionBusy}
        XCTAssertNil(model.errorMessage,"An ungenerated mask plan must not prevent static composition editing")
        XCTAssertNotNil(model.compositionCrop)
        model.togglePreview();XCTAssertFalse(model.isPlaying,"Do not play an unprotected stale preview")
        model.finishComposition(commit:true)
        model.confirmProcessing();try await waitUntil {model.route == .export || model.errorMessage != nil}
        XCTAssertNil(model.errorMessage);XCTAssertEqual(model.phase,.readyToExport)
        XCTAssertTrue(model.project?.redactionPlan?.covers(model.project!) == true)
        let analyses=await pipeline.analyses,masks=await pipeline.redactionCalls
        XCTAssertEqual(analyses,0,"Camera analysis remains reusable")
        XCTAssertEqual(masks,1,"Confirm must generate the edited mask region")
    }
    func testBuiltInStickersPersistPixelsAndFullBodyRejectsImageStyle() throws {
        let model=AppModel();model.startDemo()
        defer {model.goHome()}
        model.selectTarget(DemoStage.body(index:1,time:0));model.beginRedaction()
        for sticker in RedactionSticker.allCases {
            let data=try XCTUnwrap(sticker.data)
            let image=try XCTUnwrap(RedactionImage.decode(data))
            XCTAssertNotEqual(image.alphaInfo,.none)
            model.setRedactionSticker(sticker)
            XCTAssertEqual(model.project?.settings.redaction.imageData,data)
            XCTAssertEqual(model.project?.settings.redaction.style,.image)
        }
        let saved=try JSONEncoder().encode(model.project!.settings.redaction)
        let restored=try JSONDecoder().decode(RedactionSettings.self,from:saved)
        XCTAssertEqual(restored.imageData,RedactionSticker.alien.data)
        model.setRedactionRegion(.person)
        XCTAssertEqual(model.project?.settings.redaction.style,.frosted)
        model.setRedactionStyle(.image);model.setRedactionSticker(.cat)
        XCTAssertEqual(model.project?.settings.redaction.style,.frosted)
        model.setRedactionRegion(.face);model.setRedactionStyle(.image)
        XCTAssertEqual(model.project?.settings.redaction.imageData,restored.imageData)
    }
    func testImmediateMaskSettingsPreserveDisabledChoiceAcrossTools() async throws {
        let model=AppModel();model.startDemo()
        let primary=DemoStage.body(index:1,time:0)
        model.selectTarget(primary);model.enableAutomaticRedaction();model.beginRedaction()
        model.setRedactionStyle(.mosaic);model.finishRedaction(commit:true)
        XCTAssertEqual(model.project?.settings.redaction.style,.mosaic)
        XCTAssertTrue(model.project!.settings.redaction.enabled)
        model.beginRedaction();model.clearRedactions();model.finishRedaction(commit:true)
        model.beginRedaction()
        XCTAssertFalse(model.project!.settings.redaction.enabled,"Opening the panel must not turn masking back on")
        model.setRedactionStyle(.image)
        XCTAssertNotNil(model.project?.settings.redaction.imageData)
        model.finishRedaction(commit:true)
        XCTAssertFalse(model.project!.settings.redaction.enabled)
        XCTAssertEqual(model.project?.target,primary)
        model.goHome()
    }
    func testPrimaryExclusionUsesTrackedPositionAndCleansLegacyConflict() throws {
        var project=VideoProject.demo;project.isDemo=false
        project.target = .init(x:0.1,y:0.1,width:0.2,height:0.7)
        let moved=NormalizedRect(x:0.6,y:0.1,width:0.2,height:0.7)
        let samples=[TargetSample(time:0,body:project.target!),TargetSample(time:1,body:moved)]
        let model=AppModel();model.project=project;model.currentTime=1;model.targetSamples=samples;model.hasCompletedTracking=true
        XCTAssertFalse(model.canRedactPerson(moved));XCTAssertTrue(model.canRedactPerson(project.target!))
        let conflict=RedactionSubject(anchors:[.init(time:1,body:moved)])
        project.settings.redaction.subjects=[conflict]
        XCTAssertEqual(RedactionPolicy.conflicts(project:project,samples:samples),[conflict.id])
        project.settings.redaction.subjects=[.init(anchors:[.init(time:0,body:project.target!)])]
        model.open(project)
        XCTAssertTrue(model.project!.settings.redaction.allOthers)
        XCTAssertTrue(model.project!.settings.redaction.subjects.isEmpty)
        model.goHome()
    }
    private func waitUntil(_ condition:() -> Bool) async throws {
        for _ in 0..<600 {if condition() {return};try await Task.sleep(for:.milliseconds(5))}
        XCTFail("Expected state was not reached")
    }
}
