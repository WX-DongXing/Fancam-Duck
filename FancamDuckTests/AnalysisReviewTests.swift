import XCTest
@testable import FancamDuck

private actor QueueDetectionGate {
    private var open=false
    private var waiting:[CheckedContinuation<Void,Never>]=[]
    func wait() async {if open {return};await withCheckedContinuation {waiting.append($0)}}
    func release() {open=true;waiting.forEach {$0.resume()};waiting=[]}
}
private actor QueueTracker:TargetTracking {
    let gate:QueueDetectionGate?
    let retryRecovery:Bool
    init(gate:QueueDetectionGate?=nil,retryRecovery:Bool=false) {self.gate=gate;self.retryRecovery=retryRecovery}
    private(set) var calls:[Int:Int]=[:]
    private(set) var analyses=0
    let box=NormalizedRect(x:0.3,y:0.2,width:0.2,height:0.6)
    func detections(source:URL,time:Double,region:NormalizedRect?) async throws -> [PersonObservation] {
        let key=AnalysisSampling.key(time);calls[key,default:0]+=1
        if key>0,let gate {await gate.wait()}
        if retryRecovery,key==5000,calls[key] == 1 {throw TrackingError.invalidInput}
        return key==5000 && (!retryRecovery || calls[key,default:0]<2) ? [] : [.init(id:1,body:box,confidence:0.95,embedding:[1,0])]
    }
    func analyze(source:URL,project:VideoProject,onUpdate:@escaping @Sendable(TrackingUpdate) async -> Void) async throws -> TrackingResult {
        analyses+=1
        let samples=(0...6).filter {$0 != 1 && $0 != 3}.map {TargetSample(time:Double($0)/6,body:box)}
        return .init(samples:samples,issue:.init(time:1.0/6,message:"待确认",checkpoint:1),reviewTimes:[1.0/6,0.5])
    }
}
final class AnalysisReviewTests:XCTestCase {
    func testSixHzAndExplicitManualConfirmationPreserveExactBox() throws {
        XCTAssertEqual(AnalysisSampling.interval,1.0/6)
        let box=NormalizedRect(x:0.11,y:0.23,width:0.21,height:0.55)
        var review=AnalysisReview(frames:[.init(time:0.5)],samples:[],people:[:])
        XCTAssertFalse(review.confirm(time:0.2,box:box))
        review.failureMessages=[5000:"Failed frame"]
        XCTAssertTrue(review.confirm(time:0.5,box:box))
        XCTAssertNil(review.failureMessages?[5000])
        XCTAssertTrue(review.pending.isEmpty)
        XCTAssertEqual(review.samples.first?.body,box)
        XCTAssertEqual(try JSONDecoder().decode(AnalysisReview.self,from:JSONEncoder().encode(review)).frames,review.frames)
    }
    @MainActor private func wait(_ condition:()->Bool) async throws {
        for _ in 0..<500 {if condition(){return};try await Task.sleep(for:.milliseconds(10))}
        XCTFail("Timed out")
    }
    @MainActor func testReviewDetectsEachPointOnceAndManualDoesNotResumeAnalysis() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory),tracker=QueueTracker()
        try await store.prepare()
        // The injected pipeline needs no real video; metadata and project persistence are real.
        let source=directory.appendingPathComponent("source.mp4");try Data([0]).write(to:source)
        var p=VideoProject(title:"Queue",sourceFileName:"source.mp4",metadata:.init(width:1920,height:1080,duration:1,frameRate:30),settings:EditSettings())
        p.settings.end=1
        try await store.save(p)
        let model=AppModel(store:store,pipeline:tracker)
        model.open(p);try await wait {!model.restoringTracking && !model.detecting && !model.observations.isEmpty}
        model.selectTarget(model.observations[0].body);model.advanceWorkflow()
        try await wait {model.isReviewing && !model.detecting}
        let first=1.0/6
        XCTAssertEqual(model.reviewFrames.count,2)
        model.selectTarget(model.observations[0].body);model.confirmReviewFrame()
        XCTAssertNotNil(model.currentReviewFrame?.body)
        XCTAssertEqual(model.analysisReview?.pending.count,1)
        model.moveReview(1);try await wait {!model.detecting}
        XCTAssertEqual(model.currentTime,0.5)
        XCTAssertTrue(model.observations.isEmpty)
        model.selectReviewFrame(at:first);model.selectReviewFrame(at:0.5)
        try await Task.sleep(for:.milliseconds(50))
        let calls=await tracker.calls
        XCTAssertEqual(calls[AnalysisSampling.key(first)],1)
        XCTAssertEqual(calls[5000],1)
        let manual=NormalizedRect(x:0.17,y:0.22,width:0.26,height:0.63)
        model.beginManualSelection();XCTAssertTrue(model.finishManualBox(manual))
        try await wait {model.hasCompletedTracking}
        XCTAssertEqual(model.phase,.editing)
        XCTAssertEqual(model.targetSamples.first {abs($0.time-0.5)<0.001}?.body,manual)
        let analyses=await tracker.analyses,after=await tracker.calls
        XCTAssertEqual(analyses,1);XCTAssertEqual(after,calls)
        let saved=try await store.analysis(for:try XCTUnwrap(model.project))
        XCTAssertNotNil(saved)
        model.goHome()
    }
    @MainActor func testExplicitRetryBypassesOnlyCurrentCacheAndCanRecoverFromFailure() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory),tracker=QueueTracker(retryRecovery:true)
        try await store.prepare();try Data([1]).write(to:directory.appendingPathComponent("source.mp4"))
        let box=NormalizedRect(x:0.3,y:0.2,width:0.2,height:0.6)
        var p=VideoProject(title:"Retry",sourceFileName:"source.mp4",metadata:.init(width:1920,height:1080,duration:1,frameRate:30),settings:EditSettings())
        p.settings.end=1;p.target=box
        try await store.save(p)
        let review=AnalysisReview(frames:[.init(time:0.5)],samples:(0...6).filter {$0 != 3}.map {.init(time:Double($0)/6,body:box)},people:[5000:.init(primary:[],relaxed:[])],detected:[5000])
        try await store.saveReview(review,project:p)
        let model=AppModel(store:store,pipeline:tracker)
        model.open(p);try await wait {model.isReviewing && !model.restoringTracking}
        XCTAssertTrue(model.canRetryReviewDetection)
        let initial=await tracker.calls;XCTAssertTrue(initial.isEmpty)
        model.retryCurrentReviewDetection();model.retryCurrentReviewDetection()
        try await wait {!model.detecting}
        XCTAssertTrue(model.detectionNotice?.contains("无法读取") == true)
        let snapshot=try XCTUnwrap(model.analysisReview)
        let decoded=try JSONDecoder().decode(AnalysisReview.self,from:JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.failureMessages?[5000],model.detectionNotice)
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot)) as? [String:Any])
        legacy.removeValue(forKey:"failureMessages")
        let migrated=try JSONDecoder().decode(AnalysisReview.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(migrated.failureMessages)
        let failedCalls=await tracker.calls;XCTAssertEqual(failedCalls[5000],1)
        model.selectReviewFrame(at:0.5)
        XCTAssertTrue(model.detectionNotice?.contains("无法读取") == true,"Cached failures must retain their cause")
        let navigatedCalls=await tracker.calls;XCTAssertEqual(navigatedCalls[5000],1,"Navigation must not trigger another attempt")
        model.retryCurrentReviewDetection();model.retryCurrentReviewDetection()
        try await wait {!model.detecting}
        let retriedCalls=await tracker.calls;XCTAssertEqual(retriedCalls[5000],2)
        XCTAssertFalse(model.observations.isEmpty)
        XCTAssertNil(model.analysisReview?.failureMessages?[5000])
        XCTAssertNil(model.reviewSelection,"Retry must not select a person automatically")
        XCTAssertNil(model.currentReviewFrame?.body)
        model.selectTarget(box);model.confirmReviewFrame()
        try await wait {model.hasCompletedTracking}
        let analyses=await tracker.analyses;XCTAssertEqual(analyses,0,"Retry must never restart video analysis")
        model.goHome()
    }
    @MainActor func testReviewPersistsConfirmedAndEmptyDetectionsAcrossReopen() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory),tracker=QueueTracker()
        try await store.prepare();try Data([1]).write(to:directory.appendingPathComponent("source.mp4"))
        var p=VideoProject(title:"Review",sourceFileName:"source.mp4",metadata:.init(width:1920,height:1080,duration:1,frameRate:30),settings:EditSettings())
        p.settings.end=1;p.target = .init(x:0.3,y:0.2,width:0.2,height:0.6)
        try await store.save(p)
        var review=AnalysisReview(frames:[.init(time:1.0/6),.init(time:0.5)],samples:[.init(time:0,body:p.target!),.init(time:1,body:p.target!)],people:[5000:.init(primary:[],relaxed:[])],detected:[5000])
        XCTAssertTrue(review.confirm(time:1.0/6,box:p.target!));try await store.saveReview(review,project:p)
        let model=AppModel(store:store,pipeline:tracker);model.open(p)
        try await wait {model.isReviewing && !model.restoringTracking}
        XCTAssertEqual(model.currentTime,0.5);XCTAssertFalse(model.detecting)
        XCTAssertEqual(model.analysisReview?.pending.count,1)
        let calls=await tracker.calls;XCTAssertTrue(calls.isEmpty)
        model.goHome()
    }
    @MainActor func testInFlightNavigationIsDeduplicatedAndLateResultsCannotReplaceAnotherProject() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ProjectStore(directory:directory),gate=QueueDetectionGate(),tracker=QueueTracker(gate:gate)
        try await store.prepare();try Data([1]).write(to:directory.appendingPathComponent("source.mp4"))
        var p=VideoProject(title:"Late review",sourceFileName:"source.mp4",metadata:.init(width:1920,height:1080,duration:1,frameRate:30),settings:EditSettings())
        p.settings.end=1;p.target = .init(x:0.3,y:0.2,width:0.2,height:0.6)
        try await store.save(p)
        let review=AnalysisReview(frames:[.init(time:1.0/6),.init(time:0.5)],samples:[],people:[:])
        try await store.saveReview(review,project:p)
        let model=AppModel(store:store,pipeline:tracker);model.open(p)
        try await wait {model.isReviewing && model.detecting}
        model.selectReviewFrame(at:0.5);model.selectReviewFrame(at:1.0/6)
        for _ in 0..<100 {if await tracker.calls.count==2 {break};try await Task.sleep(for:.milliseconds(5))}
        let before=await tracker.calls
        XCTAssertEqual(before[1667],1);XCTAssertEqual(before[5000],1)
        model.goHome();model.startDemo()
        let newID=model.project?.id
        await gate.release();try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(model.isReviewing);XCTAssertEqual(model.project?.id,newID)
        XCTAssertTrue(model.observations.isEmpty)
        let after=await tracker.calls;XCTAssertEqual(before,after)
        model.goHome()
    }

}
