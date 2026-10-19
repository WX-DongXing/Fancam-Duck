import XCTest
import AVFoundation
@testable import FancamDuck

private actor RoundTracker:TargetTracking {
    private(set) var calls=0
    private(set) var detectionsCount=0
    let body=NormalizedRect(x:0.3,y:0.2,width:0.15,height:0.5)
    func detections(source:URL,time:Double,region:NormalizedRect?) -> [PersonObservation] {
        detectionsCount+=1;return [.init(id:1,body:body,confidence:0.9)]
    }
    func analyze(source:URL,project:VideoProject,onUpdate:@escaping @Sendable (TrackingUpdate) async -> Void) async throws -> TrackingResult {
        calls+=1
        var samples:[TargetSample]=[];var time=project.settings.start
        while time<project.settings.end {samples.append(.init(time:time,body:body));time+=0.1}
        samples.append(.init(time:project.settings.end,body:body));return .init(samples:samples,issue:nil)
    }
}
private actor RoundPhotoSaver:PhotoSaving {
    private(set) var calls=0
    func saveToPhotos(url:URL) async throws {calls+=1;try await Task.sleep(for:.milliseconds(100))}
}
@MainActor final class OptimizationRoundOneTests:XCTestCase {
    private var root:URL!
    private var store:ProjectStore!
    override func setUp() async throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store=ProjectStore(directory:root)}
    override func tearDown() async throws {try? FileManager.default.removeItem(at:root)}
    private func project() async throws -> VideoProject {
        let fixture=try TestVideoFixture.people()
        let source=try await store.importFile(fixture)
        var p=VideoProject(title:"Round one",sourceFileName:source.lastPathComponent,metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        p.settings.end=1.4;p.settings.resolution = .init(width:180,height:320)
        p.target = .init(x:0.3,y:0.2,width:0.15,height:0.5)
        try await store.save(p);return p
    }
    private func wait(_ predicate:()->Bool) async throws {
        for _ in 0..<500 {if predicate(){return};try await Task.sleep(for:.milliseconds(10))}
        XCTFail("Round one async state timed out")
    }
    private func samples(_ p:VideoProject) -> [TargetSample] {(0...14).map {.init(time:Double($0)*0.1,body:p.target!)}}
    func testDiskCacheSurvivesReopenAndTrimWithoutAnalysis() async throws {
        let p=try await project(),tracker=RoundTracker(),model=AppModel(store:store,pipeline:tracker)
        model.open(p);try await wait {!model.detecting && !model.restoringTracking}
        model.confirmProcessing();try await wait {model.route == .export}
        let saved=try XCTUnwrap(model.project)
        model.goHome();model.open(saved);try await wait {!model.detecting && !model.restoringTracking}
        XCTAssertTrue(model.hasCompletedTracking)
        model.updateRange(start:0.23);model.updateRange(end:1.03)
        try await wait {!model.detecting}
        XCTAssertTrue(model.hasCompletedTracking);XCTAssertNotNil(model.project?.target)
        model.confirmProcessing();try await wait {model.route == .export}
        let calls=await tracker.calls;XCTAssertEqual(calls,1)
        model.goHome()
    }
    func testCacheRequiresSameSourceIdentityAndVersionButNotOutputSettings() async throws {
        let p=try await project();try await store.saveTrajectory(project:p,samples:samples(p))
        var edited=p;edited.settings.start=0.23;edited.settings.end=1.03;edited.settings.compositionScale=1.5;edited.settings.resolution = .init(width:360,height:640)
        let reusable=try await store.trajectory(for:edited);XCTAssertNotNil(reusable)
        edited.target?.x=0.5
        let wrongTarget=try await store.trajectory(for:edited);XCTAssertNil(wrongTarget)
        let file=root.appendingPathComponent("trajectory-\(p.id).json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]);json["version"]="old-policy"
        try JSONSerialization.data(withJSONObject:json).write(to:file)
        let wrongVersion=try await store.trajectory(for:p);XCTAssertNil(wrongVersion)
        try await store.saveTrajectory(project:p,samples:samples(p))
        let source=try XCTUnwrap(store.sourceURL(for:p));let handle=try FileHandle(forWritingTo:source);try handle.seekToEnd();try handle.write(contentsOf:Data([0]));try handle.close()
        let changedSource=try await store.trajectory(for:p);XCTAssertNil(changedSource)
    }
    func testDeleteRemovesTrajectoryAndDoesNotResurrectIt() async throws {
        let p=try await project();try await store.saveTrajectory(project:p,samples:samples(p));try await store.remove(p)
        try await store.saveTrajectory(project:p,samples:samples(p))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("trajectory-\(p.id).json").path))
    }
    func testNonFrameAlignedTrimPreservesOriginalCameraAtBothBoundaries() {
        let frames=(0...10).map {CropPlan.Frame(time:Double($0)*0.04,rect:.init(x:100+Double($0)*2,y:40,width:180,height:320))}
        let trimmed=CropPlan.clipped(frames,start:0.023,end:0.357)
        XCTAssertEqual(trimmed.first?.rect.minX,101.15)
        XCTAssertEqual(trimmed.last!.rect.minX,117.85,accuracy:0.00001)
        XCTAssertEqual(trimmed.first?.time,0.023);XCTAssertEqual(trimmed.last?.time,0.357)
    }
    func testScrubDoesNotDetectUntilRelease() async throws {
        let p=try await project(),tracker=RoundTracker(),model=AppModel(store:store,pipeline:tracker)
        model.open(p);try await wait {!model.detecting && !model.restoringTracking}
        let before=await tracker.detectionsCount
        for i in 0..<10 {model.scrub(to:Double(i)*0.1)}
        try await Task.sleep(for:.milliseconds(200))
        let during=await tracker.detectionsCount;XCTAssertEqual(during,before)
        model.finishScrubbing();try await wait {!model.detecting}
        let after=await tracker.detectionsCount;XCTAssertEqual(after,before+1);model.goHome()
    }
    func testRepeatedSaveWritesOnlyOnce() async throws {
        let saver=RoundPhotoSaver(),model=AppModel(photoSaver:saver)
        model.outputURL=root.appendingPathComponent("output.mp4")
        async let first:Void=model.saveVideo()
        async let second:Void=model.saveVideo()
        _=await(first,second)
        let calls=await saver.calls;XCTAssertEqual(calls,1);XCTAssertTrue(model.savedToPhotos);XCTAssertFalse(model.savingToPhotos)
    }
}
