import XCTest
@testable import FancamDuck

final class SubjectCompositionTests:XCTestCase {
    private let source=CGSize(width:1920,height:1080)
    private func samples()->[TargetSample] {
        (0...60).map {i in
            let t=Double(i)/6,scale=1+Double(i)*0.004
            let x=0.45+0.025*sin(t),y=0.48+0.025*cos(t)
            var pose=Array(repeating:PosePoint(x:x,y:y,confidence:0),count:17)
            for j in [5,6] {pose[j] = .init(x:x+(j==5 ? -0.025 : 0.025)*scale,y:y-0.12*scale,confidence:0.95)}
            for j in [11,12] {pose[j] = .init(x:x+(j==11 ? -0.02 : 0.02)*scale,y:y,confidence:0.95)}
            return .init(time:t,body:.init(x:x-0.06*scale,y:y-0.25*scale,width:0.12*scale,height:0.45*scale),focusX:x,keypoints:pose)
        }
    }
    func testPersistentTargetsFollowBothAxesAndScaleAtEveryTime() throws {
        let samples=samples(),subjects=SubjectFraming.make(samples,source:source)
        var settings=EditSettings();settings.subjectComposition = .init(height:0.75,x:0.04,y:-0.02)
        let plan=CropPlan.renderFrames(CropPlan.make(samples:samples,source:source,settings:settings),frameRate:30)
        XCTAssertGreaterThan(plan.last!.rect.height,plan.first!.rect.height*1.1)
        for time in stride(from:0.05,through:9.95,by:0.13) {
            let subject=try XCTUnwrap(SubjectFraming.frame(at:time,in:subjects)),crop=try XCTUnwrap(CropPlan.rect(at:time,in:plan))
            XCTAssertEqual((subject.center.x*source.width-crop.minX)/crop.width,0.54,accuracy:0.012)
            XCTAssertEqual((subject.center.y*source.height-crop.minY)/crop.height,0.48,accuracy:0.012)
            XCTAssertEqual(subject.height*source.height/crop.height,0.75,accuracy:0.012)
            XCTAssertEqual(crop.width/crop.height,settings.aspectRatio.value,accuracy:0.00001)
        }
    }
    func testCrouchDoesNotZoomAndEdgeReturnsToConfiguredCenter() throws {
        var samples=samples()
        for i in 20...30 {let s=samples[i];var body=s.body;body.height *= 0.5;samples[i] = .init(time:s.time,body:body,focusX:s.focusX,keypoints:s.keypoints)}
        let subjects=SubjectFraming.make(samples,source:source)
        XCTAssertEqual(subjects[25].height/subjects[15].height,1.1/1.06,accuracy:0.04)
        for i in 10...20 {let s=samples[i];var body=s.body;body.x=0.9;samples[i] = .init(time:s.time,body:body,focusX:0.98)}
        let settings=EditSettings(),plan=CropPlan.renderFrames(CropPlan.make(samples:samples,source:source,settings:settings),frameRate:30)
        for frame in plan {
            XCTAssertGreaterThanOrEqual(frame.rect.minX,-0.0001);XCTAssertGreaterThanOrEqual(frame.rect.minY,-0.0001)
            XCTAssertLessThanOrEqual(frame.rect.maxX,source.width+0.0001);XCTAssertLessThanOrEqual(frame.rect.maxY,source.height+0.0001)
        }
        let crop=try XCTUnwrap(CropPlan.rect(at:8,in:plan)),subject=try XCTUnwrap(SubjectFraming.frame(at:8,in:SubjectFraming.make(samples,source:source)))
        XCTAssertEqual((subject.center.x*source.width-crop.minX)/crop.width,0.5,accuracy:0.012)
        XCTAssertEqual(settings.subjectComposition?.x,0)
    }
    func testOldSettingsStayLegacyAndNewTargetsRoundTrip() throws {
        XCTAssertEqual(SubjectComposition().height,0.60)
        let legacy=try JSONDecoder().decode(EditSettings.self,from:Data("{}".utf8))
        XCTAssertNil(legacy.subjectComposition)
        var settings=EditSettings();settings.subjectComposition = .init(height:0.66,x:-0.07,y:0.03)
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self,from:JSONEncoder().encode(settings)),settings)
    }
    func testTargetsSurviveStoreReopeningAndAmbiguousCachedPoseIsNotBorrowed() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=ProjectStore(directory:root)
        var project=VideoProject.demo
        project.settings.subjectComposition = .init(height:0.72,x:0.03,y:-0.05)
        try await store.save(project)
        let loaded=try await ProjectStore(directory:root).projects()
        XCTAssertEqual(loaded.first?.settings.subjectComposition,project.settings.subjectComposition)
        let s=samples()[0],old=TargetSample(time:s.time,body:s.body)
        let person=PersonObservation(id:1,body:s.body,confidence:1,keypoints:s.keypoints ?? [])
        let key=AnalysisSampling.key(s.time)
        XCTAssertNotNil(SubjectFraming.withCachedPoses([old],people:[key:.init(primary:[person],relaxed:[])])[0].keypoints)
        XCTAssertNil(SubjectFraming.withCachedPoses([old],people:[key:.init(primary:[person,person],relaxed:[])])[0].keypoints)
    }
    @MainActor func testZoomKeepsRequestedSizeWhenSourceEdgesLimitActualSize() async throws {
        let model=AppModel();model.prepareCompositionDemo()
        for _ in 0..<500 {if !model.compositionBusy {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(model.project?.settings.subjectComposition?.height,0.60)
        XCTAssertGreaterThan(try XCTUnwrap(model.compositionReadout).height,0.60)
        model.compositionZoom(1.1)
        XCTAssertEqual(try XCTUnwrap(model.project?.settings.subjectComposition).height,0.66,accuracy:0.00001)
        model.goHome()
    }
    @MainActor func testEditingAtAnotherTimeChangesWholeSegmentAndSingleAxisCenterKeepsOtherGoals() async throws {
        let model=AppModel();model.startDemo();model.selectTarget(.init(x:0.42,y:0.25,width:0.12,height:0.45))
        model.hasCompletedTracking=true;model.targetSamples=samples();model.project?.settings.end=10
        model.beginComposition()
        func settle() async throws {
            for _ in 0..<500 {if !model.compositionBusy {return};try await Task.sleep(for:.milliseconds(10))}
            XCTFail("Composition did not settle")
        }
        try await settle()
        model.seek(to:2);model.compositionMove(x:0.04,y:-0.02);try await settle()
        let first=try XCTUnwrap(model.project?.settings.subjectComposition)
        model.seek(to:8)
        XCTAssertEqual(model.project?.settings.subjectComposition,first)
        model.compositionZoom(1.1);try await settle()
        let changed=try XCTUnwrap(model.project?.settings.subjectComposition)
        XCTAssertGreaterThan(changed.height,first.height);XCTAssertEqual(changed.x,first.x);XCTAssertEqual(changed.y,first.y)
        model.centerComposition(horizontal:true);try await settle()
        let centered=try XCTUnwrap(model.project?.settings.subjectComposition)
        XCTAssertEqual(centered.x,0);XCTAssertEqual(centered.y,changed.y);XCTAssertEqual(centered.height,changed.height)
        XCTAssertTrue(model.compositionCentered(horizontal:true))
        XCTAssertTrue(model.compositionStatusText.contains("水平 0%"))
        XCTAssertFalse(model.compositionStatusText.contains("."))
        model.seek(to:2)
        XCTAssertEqual(model.project?.settings.subjectComposition,centered)
        XCTAssertNotNil(model.compositionPrimaryBody)
        XCTAssertFalse(model.compositionStatusText.contains("—"))
        model.goHome()
    }
}
