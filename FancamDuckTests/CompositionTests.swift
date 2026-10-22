import XCTest
import AVFoundation
@testable import FancamDuck

private actor CompositionTracker:TargetTracking {
    private(set) var calls=0
    let body=NormalizedRect(x:0.35,y:0.25,width:0.15,height:0.5)
    func detections(source:URL,time:Double,region:NormalizedRect?) -> [PersonObservation] { [.init(id:1,body:body,confidence:0.9)] }
    func analyze(source:URL,project:VideoProject,onUpdate:@escaping @Sendable (TrackingUpdate) async -> Void) async throws -> TrackingResult {
        calls+=1
        return .init(samples:(0...7).map {.init(time:Double($0)*0.1,body:body)},issue:nil)
    }
}
final class CompositionTests:XCTestCase {
    func testShortWorkspaceCanKeepCanvasBesideRecoveryOrExportControls() {
        XCTAssertTrue(WorkspaceLayout.usesColumns(in:.init(width:734,height:281)))
        XCTAssertTrue(WorkspaceLayout.usesColumns(in:.init(width:667,height:271)))
        XCTAssertFalse(WorkspaceLayout.usesColumns(in:.init(width:390,height:700)))
        XCTAssertFalse(WorkspaceLayout.usesColumns(in:.init(width:560,height:900)))
        XCTAssertTrue(WorkspaceLayout.usesColumns(in:.init(width:594,height:350)))
        XCTAssertEqual(WorkspaceLayout.controlsWidth(in:.init(width:594,height:350)),336)
        XCTAssertEqual(WorkspaceLayout.controlsWidth(in:.init(width:900,height:600)),360)
        XCTAssertFalse(WorkspaceLayout.usesColumns(in:.init(width:900,height:200)))
    }
    func testPreviewWorkspaceAdaptsToWindowInsteadOfDeviceName() {
        XCTAssertEqual(PreviewWorkspaceLayout.resolve(size:.init(width:390,height:750),regularWidth:false),.phone)
        XCTAssertEqual(PreviewWorkspaceLayout.resolve(size:.init(width:450,height:600),regularWidth:false,sideInsets:true),.outer)
        XCTAssertEqual(PreviewWorkspaceLayout.resolve(size:.init(width:640,height:390),regularWidth:false),.outer)
        XCTAssertEqual(PreviewWorkspaceLayout.resolve(size:.init(width:980,height:650),regularWidth:true),.wide)
        XCTAssertEqual(PreviewWorkspaceLayout.resolve(size:.init(width:650,height:980),regularWidth:true),.portrait)
        XCTAssertEqual(PreviewWorkspaceLayout.resolve(size:.init(width:650,height:650),regularWidth:true),.portrait)
        XCTAssertEqual(PreviewWorkspaceLayout.resolve(size:.init(width:450,height:650),regularWidth:false),.phone)
    }

    func testAllAspectPathsPreserveViewportAndSourceBounds() throws {
        let source=CGSize(width:1920,height:1080)
        let samples=(0...10).map {TargetSample(time:Double($0)/10,body:.init(x:0.3+Double($0)*0.01,y:0.2,width:0.15,height:0.6))}
        for aspect in OutputAspectRatio.allCases {
            var settings=EditSettings();settings.aspectRatio=aspect
            let automatic=CropPlan.make(samples:samples,source:source,settings:settings)
            let chosen=CompositionGeometry.reframed(CGRect(x:400,y:200,width:300,height:500),source:source,aspect:aspect)
            settings.compositionAnchor = .init(time:0,crop:.init(x:chosen.minX/source.width,y:chosen.minY/source.height,width:chosen.width/source.width,height:chosen.height/source.height))
            let anchored=CropPlan.make(samples:samples,source:source,settings:settings)
            XCTAssertEqual(try XCTUnwrap(anchored.first).rect.minX,chosen.minX,accuracy:0.0001)
            for frame in automatic+anchored {
                XCTAssertEqual(frame.rect.width/frame.rect.height,aspect.value,accuracy:0.000001)
                XCTAssertGreaterThanOrEqual(frame.rect.minX,-0.0001);XCTAssertGreaterThanOrEqual(frame.rect.minY,-0.0001)
                XCTAssertLessThanOrEqual(frame.rect.maxX,source.width+0.0001);XCTAssertLessThanOrEqual(frame.rect.maxY,source.height+0.0001)
            }
            let changed=CompositionGeometry.transformed(chosen,scale:1.2,translation:.init(width:4,height:5),anchor:.init(x:0.2,y:0.4),viewport:.init(width:200,height:200/aspect.value))
            XCTAssertEqual(changed.width/changed.height,aspect.value,accuracy:0.000001)
            XCTAssertEqual(try JSONDecoder().decode(EditSettings.self,from:JSONEncoder().encode(settings)).aspectRatio,aspect)
        }
    }
    @MainActor func testCenteringOnlyChangesChosenAxisAndRatioCancelRestoresSettings() async throws {
        let model=AppModel();model.startDemo();model.selectTarget(DemoStage.body(index:1,time:0))
        func ready() async throws {
            for _ in 0..<400 {if !model.compositionBusy {return};try await Task.sleep(for:.milliseconds(10))}
            XCTFail("Composition timed out")
        }
        let original=try XCTUnwrap(model.project?.settings)
        model.beginComposition();try await ready()
        model.compositionZoom(1.5);try await ready();model.compositionMove(x:0.05,y:0.04);try await ready()
        let before=try XCTUnwrap(model.compositionCrop)
        model.centerComposition(horizontal:true);try await ready()
        let horizontal=try XCTUnwrap(model.compositionCrop)
        XCTAssertEqual(horizontal.midY,before.midY,accuracy:0.0001);XCTAssertEqual(horizontal.height,before.height,accuracy:0.0001)
        model.centerComposition(horizontal:false);try await ready()
        let vertical=try XCTUnwrap(model.compositionCrop)
        XCTAssertEqual(vertical.midX,horizontal.midX,accuracy:0.0001);XCTAssertEqual(vertical.width,horizontal.width,accuracy:0.0001)
        let referenceTime=model.currentTime
        model.setCompositionAspect(.classic)
        XCTAssertEqual(model.compositionCrop!.width/model.compositionCrop!.height,3.0/4,accuracy:0.0001,"Viewport and aspect must update in the same transaction")
        XCTAssertEqual(model.currentTime,referenceTime)
        try await ready()
        XCTAssertEqual(model.compositionCrop!.width/model.compositionCrop!.height,3.0/4,accuracy:0.0001)
        XCTAssertEqual(model.project?.settings.aspectRatio,.classic)
        model.finishComposition(commit:false);XCTAssertEqual(model.project?.settings,original)
        model.goHome()
    }
    @MainActor func testRapidAspectChangesWhilePreviewBusyKeepLatestSelection() async throws {
        let model=AppModel();model.startDemo();model.selectTarget(DemoStage.body(index:1,time:0))
        let original=try XCTUnwrap(model.project?.settings)
        model.beginComposition()
        for _ in 0..<400 {
            if !model.compositionBusy {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertNotNil(model.compositionCrop)
        // No suspension between selections: all changes arrive before the first task completes.
        for aspect:OutputAspectRatio in [.square,.classic,.portrait,.square] {
            model.setCompositionAspect(aspect)
            XCTAssertEqual(model.project?.settings.aspectRatio,aspect)
            let crop=try XCTUnwrap(model.compositionCrop)
            XCTAssertEqual(crop.width/crop.height,aspect.value,accuracy:0.0001)
        }
        for _ in 0..<400 {
            if !model.compositionBusy {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertFalse(model.compositionBusy)
        XCTAssertEqual(model.project?.settings.aspectRatio,.square)
        let crop=try XCTUnwrap(model.compositionCrop)
        XCTAssertEqual(crop.width/crop.height,1,accuracy:0.0001)
        model.finishComposition(commit:false)
        XCTAssertEqual(model.project?.settings,original)
        model.goHome()
    }
    @MainActor func testRapidMotionChangesKeepLatestSpeedAndComposition() async throws {
        let model=AppModel();model.startDemo();model.selectTarget(DemoStage.body(index:1,time:0))
        model.beginComposition()
        let original=try XCTUnwrap(model.project?.settings)
        for speed:EditSettings.FollowSpeed in [.standard,.responsive,.gentle,.responsive] {
            model.setFollowSpeed(speed)
            XCTAssertEqual(model.project?.settings.followSpeed,speed)
        }
        for _ in 0..<400 {
            if !model.compositionBusy {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertFalse(model.compositionBusy)
        XCTAssertNotNil(model.compositionCrop)
        XCTAssertEqual(model.project?.settings.compositionAnchor,original.compositionAnchor)
        XCTAssertEqual(model.project?.settings.aspectRatio,original.aspectRatio)
        model.finishComposition(commit:true)
        XCTAssertEqual(model.project?.settings.followSpeed,.responsive)
        model.goHome()
    }
    func testChosenViewportSurvivesFullTrajectoryAndProtectionRecalculation() throws {
        let source=CGSize(width:3840,height:2160)
        let body=NormalizedRect(x:0.43,y:0.44,width:0.05,height:0.27)
        let selected=CGRect(x:1460,y:780,width:405,height:720)
        for protect in [false,true] {
            var settings=EditSettings();settings.protectFullBody=protect
            settings.compositionAnchor = .init(time:0,crop:.init(x:selected.minX/source.width,y:selected.minY/source.height,width:selected.width/source.width,height:selected.height/source.height))
            let single=[TargetSample(time:0,body:body,focusX:0.455)]
            let full=single+(1...100).map {i in TargetSample(time:Double(i)*0.1,body:.init(x:0.35+Double(i)*0.002,y:0.15,width:0.18,height:0.7),focusX:0.455+Double(i)*0.002)}
            for samples in [single,full] {
                let plan=CropPlan.renderFrames(CropPlan.make(samples:samples,source:source,settings:settings),frameRate:25,preserving:0)
                let reference=try XCTUnwrap(CropPlan.rect(at:0,in:plan))
                XCTAssertEqual(reference.minX,selected.minX,accuracy:0.0001)
                XCTAssertEqual(reference.minY,selected.minY,accuracy:0.0001)
                XCTAssertEqual(reference.height,selected.height,accuracy:0.0001)
                XCTAssertTrue(plan.allSatisfy {abs($0.rect.height-selected.height)<0.0001})
            }
            let restored=try JSONDecoder().decode(EditSettings.self,from:JSONEncoder().encode(settings))
            XCTAssertEqual(restored.compositionAnchor,settings.compositionAnchor)
        }
    }
    func testReferenceBetweenAnalysisAndOutputFramesRemainsExact() throws {
        let source=CGSize(width:1920,height:1080),time=0.137
        let samples=(0...20).map {TargetSample(time:Double($0)*0.1,body:.init(x:0.4+Double($0)*0.003,y:0.2,width:0.1,height:0.5))}
        var settings=EditSettings();settings.subjectComposition=nil;settings.protectFullBody=false
        settings.compositionAnchor = .init(time:time,crop:.init(x:0.3,y:0.2,width:0.1875,height:0.5925925925925926))
        let plan=CropPlan.renderFrames(CropPlan.make(samples:samples,source:source,settings:settings),frameRate:25,preserving:time)
        let rect=try XCTUnwrap(CropPlan.rect(at:time,in:plan))
        XCTAssertEqual(rect.minX,576,accuracy:0.0001);XCTAssertEqual(rect.minY,216,accuracy:0.0001)
        XCTAssertEqual(rect.width,360,accuracy:0.0001);XCTAssertEqual(rect.height,640,accuracy:0.0001)
        XCTAssertTrue(zip(plan,plan.dropFirst()).allSatisfy {$0.time<$1.time})
    }
    func testFullBodyAtSourceEdgeStillConstrainsPanWithoutOptionalPadding() {
        let body=NormalizedRect(x:0,y:0.3,width:0.14,height:0.4)
        let samples=(0...5).map {TargetSample(time:Double($0)*0.1,body:body)}
        var settings=EditSettings();settings.compositionScale=2;settings.compositionX = -0.5
        let plan=CropPlan.make(samples:samples,source:.init(width:1920,height:1080),settings:settings)
        XCTAssertTrue(plan.allSatisfy {$0.rect.minX<0.001 && $0.rect.maxX>=body.width*1920})
        let proposed=CGRect(x:300,y:0,width:300,height:300*16/9)
        let constrained=CompositionGeometry.constrain(proposed,source:.init(width:1920,height:1080),samples:samples,reference:samples[0],protect:true)
        XCTAssertEqual(constrained.minX,0,accuracy:0.001)
    }
    func testOldSettingsDecodeAndNewSettingsRoundTrip() throws {
        let old=try JSONDecoder().decode(EditSettings.self,from:Data("{\"start\":1,\"end\":3,\"personHeight\":0.6}".utf8))
        XCTAssertEqual(old.aspectRatio,.portrait);XCTAssertEqual(old.followSpeed, .standard); XCTAssertEqual(EditSettings().followSpeed, .standard)
        XCTAssertFalse(EditSettings().redaction.enabled)
        let saved=try JSONDecoder().decode(EditSettings.self,from:Data("{\"followSpeed\":\"舒缓\"}".utf8))
        XCTAssertEqual(saved.followSpeed,.gentle)
        XCTAssertEqual(old.compositionScale,1);XCTAssertEqual(old.compositionX,0);XCTAssertEqual(old.start,1)
        var settings=old;settings.compositionScale=1.4;settings.compositionX=0.1;settings.compositionY = -0.1
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self,from:JSONEncoder().encode(settings)),settings)
    }
    func testPinchPreservesFingerAnchorAndPanFollowsFinger() {
        let rect=CGRect(x:200,y:100,width:450,height:800),anchor=CGPoint(x:0.25,y:0.7)
        let transformed=CompositionGeometry.transformed(rect,scale:1.5,translation:.zero,anchor:anchor,viewport:.init(width:225,height:400))
        XCTAssertEqual(rect.minX+anchor.x*rect.width,transformed.minX+anchor.x*transformed.width,accuracy:0.0001)
        XCTAssertEqual(rect.minY+anchor.y*rect.height,transformed.minY+anchor.y*transformed.height,accuracy:0.0001)
        let moved=CompositionGeometry.transformed(rect,scale:1,translation:.init(width:20,height:10),anchor:anchor,viewport:.init(width:225,height:400))
        XCTAssertLessThan(moved.minX,rect.minX);XCTAssertLessThan(moved.minY,rect.minY)
    }
    func testZoomAndPlacementAreSharedByStableCameraAndBounds() {
        let samples=(0...10).map {TargetSample(time:Double($0)*0.1,body:.init(x:0.4+Double($0)*0.001,y:0.3,width:0.12,height:0.35))}
        var settings=EditSettings();settings.subjectComposition=nil;settings.protectFullBody=false
        let original=CropPlan.make(samples:samples,source:.init(width:1920,height:1080),settings:settings)
        settings.compositionScale=1.3;settings.compositionX=0.1;settings.compositionY = -0.08
        let updated=CropPlan.make(samples:samples,source:.init(width:1920,height:1080),settings:settings)
        XCTAssertEqual(original[0].rect.height/updated[0].rect.height,1.3,accuracy:0.001)
        XCTAssertLessThan(updated[0].rect.midX,original[0].rect.midX)
        XCTAssertGreaterThan(updated[0].rect.midY,original[0].rect.midY)
        XCTAssertTrue(updated.allSatisfy {$0.rect.minX>=0 && $0.rect.minY>=0 && $0.rect.maxX<=1920.001 && $0.rect.maxY<=1080.001})
        XCTAssertEqual(updated.first!.rect.height,updated.last!.rect.height)
    }
    @MainActor func testPreAnalysisCompositionIsUsedAfterConfirmingProcessing() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory),tracker=CompositionTracker()
        let fixture=try TestVideoFixture.people()
        let source=try await store.importFile(fixture)
        var p=VideoProject(title:"Anchor regression",sourceFileName:source.lastPathComponent,metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        p.settings.end=0.7;p.settings.resolution = .init(width:180,height:320)
        let model=AppModel(store:store,pipeline:tracker)
        func wait(_ predicate:()->Bool) async throws {
            for _ in 0..<400 {if predicate(){return};try await Task.sleep(for:.milliseconds(10))}
            XCTFail("Timed out waiting for composition")
        }
        model.open(p);try await wait {!model.detecting};model.selectTarget(try XCTUnwrap(model.observations.first).body)
        model.beginComposition();try await wait {!model.compositionBusy}
        model.toggleCompositionProtection();try await wait {!model.compositionBusy}
        model.compositionZoom(1.2);try await wait {!model.compositionBusy}
        model.compositionMove(x:0.08,y:0.04);try await wait {!model.compositionBusy}
        let selected=try XCTUnwrap(model.compositionCrop)
        model.finishComposition(commit:true)
        let settings=try XCTUnwrap(model.project?.settings)
        model.confirmProcessing();try await wait {model.route == .export}
        XCTAssertEqual(model.project?.settings.compositionAnchor,settings.compositionAnchor)
        let plan=CropPlan.make(samples:model.targetSamples,source:p.metadata.size,settings:model.project!.settings)
        let actual=try XCTUnwrap(CropPlan.rect(at:0,in:plan))
        XCTAssertEqual(actual.minX,selected.minX,accuracy:0.0001)
        XCTAssertEqual(actual.minY,selected.minY,accuracy:0.0001)
        XCTAssertEqual(actual.height,selected.height,accuracy:0.0001)
        model.goHome()
    }
    @MainActor func testCancelUndoAndCompletedTrackingIsReused() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory),tracker=CompositionTracker()
        let fixture=try TestVideoFixture.people()
        let source=try await store.importFile(fixture)
        var p=VideoProject(title:"Composition",sourceFileName:source.lastPathComponent,metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        p.settings.end=0.7;p.settings.resolution = .init(width:180,height:320)
        let model=AppModel(store:store,pipeline:tracker)
        func wait(_ predicate:()->Bool) async throws {
            for _ in 0..<400 {if predicate(){return};try await Task.sleep(for:.milliseconds(10))}
            XCTFail("Timed out waiting for composition state")
        }
        model.open(p);try await wait {!model.detecting};model.selectTarget(try XCTUnwrap(model.observations.first).body)
        let initial=model.project!.settings
        model.beginComposition();try await wait {!model.compositionBusy};model.toggleCompositionProtection();try await wait {!model.compositionBusy}
        model.compositionZoom(1.2);try await wait {!model.compositionBusy}
        XCTAssertGreaterThan(model.project!.settings.compositionScale,1)
        model.undoComposition();try await wait {!model.compositionBusy};XCTAssertEqual(model.project?.settings.compositionScale,1)
        model.finishComposition(commit:false);XCTAssertEqual(model.project?.settings,initial)
        model.confirmProcessing();try await wait {model.route == .export}
        model.backToEditor();try await wait {!model.detecting};XCTAssertTrue(model.hasCompletedTracking)
        model.beginComposition();try await wait {!model.compositionBusy};model.toggleCompositionProtection();try await wait {!model.compositionBusy}
        model.seek(to:0.4)
        model.setFollowSpeed(.responsive);try await wait {!model.compositionBusy}
        XCTAssertEqual(model.project?.settings.followSpeed,.responsive)
        model.compositionMove(x:0.05,y:0.03);try await wait {!model.compositionBusy}
        let chosen=try XCTUnwrap(model.compositionCrop)
        model.confirmProcessing();try await wait {model.route == .export}
        let actual=try XCTUnwrap(CropPlan.rect(at:model.project!.settings.compositionAnchor!.time,in:CropPlan.make(samples:model.targetSamples,source:model.project!.metadata.size,settings:model.project!.settings)))
        XCTAssertEqual(actual.minX,chosen.minX,accuracy:0.0001)
        XCTAssertEqual(actual.minY,chosen.minY,accuracy:0.0001)
        XCTAssertEqual(actual.height,chosen.height,accuracy:0.0001)
        let calls=await tracker.calls;XCTAssertEqual(calls,1,"Changing composition must not re-run person inference")
        let saved=try XCTUnwrap(model.project)
        model.goHome();model.open(saved);try await wait {!model.detecting && !model.restoringTracking}
        model.beginComposition();try await wait {!model.compositionBusy}
        XCTAssertEqual(model.currentTime,0.4,accuracy:0.001,"A reopened project must show the saved reference frame, not the old selection frame")
        let reopened=try XCTUnwrap(model.compositionCrop)
        XCTAssertEqual(reopened.minX,chosen.minX,accuracy:0.0001)
        XCTAssertEqual(reopened.minY,chosen.minY,accuracy:0.0001)
        XCTAssertEqual(reopened.height,chosen.height,accuracy:0.0001)
        model.finishComposition(commit:false);model.goHome()
    }
    @MainActor func testTimelineRangeSurvivesCancellingCompositionAndInvalidReferenceClosesIt() async throws {
        let model = AppModel(); model.startDemo()
        let body = DemoStage.body(index: 1, time: 0)
        model.selectTarget(body)
        func ready() async throws {
            for _ in 0..<400 {
                if !model.compositionBusy { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Composition did not settle")
        }
        model.beginComposition(); try await ready()
        model.compositionZoom(0.9); try await ready()
        model.scrub(to: 45, within: 0...58.2, sourceOnly: true)
        XCTAssertEqual(model.currentTime, 45)
        model.updateRange(start: 0, end: 45, previewTime: 45); try await ready()
        XCTAssertTrue(model.compositionEditing)
        model.finishComposition(commit: false)
        XCTAssertEqual(model.project?.settings.end, 45)
        XCTAssertEqual(model.project?.settings.compositionScale, 1)
        model.beginComposition(); try await ready()
        model.updateRange(start: 5, end: 40, previewTime: 5)
        XCTAssertFalse(model.compositionEditing)
        XCTAssertNil(model.project?.target)
        XCTAssertEqual(model.project?.settings.start, 5)
        XCTAssertEqual(model.project?.settings.end, 40)
        model.goHome()
    }

}
