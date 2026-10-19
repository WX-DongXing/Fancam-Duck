import XCTest
@testable import FancamDuck

final class OcclusionBridgeTests:XCTestCase {
    private func person(_ id:Int,_ x:Double=0.3,_ feature:[Float]=[1,0]) -> PersonObservation {
        .init(id:id,body:.init(x:x,y:0.2,width:0.15,height:0.6),confidence:0.9,embedding:feature)
    }
    private var reference:TargetSample { .init(time:0,body:person(0).body,trackID:42) }
    func testShortOcclusionRecoversOnlyAfterTwoObservationsAndFillsGap() {
        var bridge=OcclusionBridge()
        for t in [0.1,0.2,0.3] {
            guard case .predicted(let sample)=bridge.step(time:t,reference:reference,predicted:reference.body,candidate:nil,directReliable:false,observations:[],gallery:[[1,0]],unavailableIDs:[],trackID:42) else { return XCTFail("Short missing detections should coast") }
            XCTAssertEqual(sample.estimated,true)
        }
        let found=person(9,0.34)
        guard case .predicted=bridge.step(time:0.4,reference:reference,predicted:reference.body,candidate:found,directReliable:true,observations:[found],gallery:[[1,0]],unavailableIDs:[],trackID:42) else { return XCTFail("One frame cannot confirm identity") }
        guard case .observed(let actual,let samples)=bridge.step(time:0.5,reference:reference,predicted:reference.body,candidate:found,directReliable:true,observations:[found],gallery:[[1,0]],unavailableIDs:[],trackID:42) else { return XCTFail("Second consistent observation should recover") }
        XCTAssertEqual(actual.id,9);XCTAssertEqual(samples.count,4)
        XCTAssertTrue(samples.allSatisfy {$0.trackID==42 && $0.estimated==true && $0.body.x>=0.3 && $0.body.x<=0.34})
        XCTAssertFalse(bridge.isActive)
    }
    func testOwnedOccluderAndSimilarLookingAmbiguousCandidatesNeverReplaceTarget() {
        var bridge=OcclusionBridge()
        let occluder=person(7)
        for t in [0.1,0.2,0.3] {
            guard case .predicted=bridge.step(time:t,reference:reference,predicted:reference.body,candidate:occluder,directReliable:false,observations:[occluder],gallery:[[1,0]],unavailableIDs:[7],trackID:42) else { return XCTFail("Another known person's observation must remain unavailable") }
        }
        for t in [0.4,0.5,0.6] {
            guard case .predicted=bridge.step(time:t,reference:reference,predicted:reference.body,candidate:nil,directReliable:false,observations:[person(8,0.27),person(9,0.33)],gallery:[[1,0]],unavailableIDs:[],trackID:42) else { return XCTFail("Equal candidates must remain uncertain") }
        }
        guard case .blocked(let time)=bridge.step(time:1.3,reference:reference,predicted:reference.body,candidate:nil,directReliable:false,observations:[],gallery:[[1,0]],unavailableIDs:[],trackID:42) else { return XCTFail("Unresolved long gap should request direct selection") }
        XCTAssertEqual(time,0.1,accuracy:0.001)
    }
    func testBackwardRecoveryInterpolatesAndCoastingDoesNotContaminateIdentity() throws {
        var bridge=OcclusionBridge()
        let ref=TargetSample(time:2,body:reference.body,trackID:42)
        _=bridge.step(time:1.9,reference:ref,predicted:ref.body,candidate:nil,directReliable:false,observations:[],gallery:[[1,0]],unavailableIDs:[],trackID:42)
        let found=person(4,0.28)
        _=bridge.step(time:1.8,reference:ref,predicted:ref.body,candidate:found,directReliable:false,observations:[found],gallery:[[1,0]],unavailableIDs:[],trackID:42)
        guard case .observed(_,let samples)=bridge.step(time:1.7,reference:ref,predicted:ref.body,candidate:found,directReliable:false,observations:[found],gallery:[[1,0]],unavailableIDs:[],trackID:42) else { return XCTFail("Backward gap should recover too") }
        XCTAssertEqual(samples.map(\.time),[1.9,1.8]);XCTAssertTrue(samples.allSatisfy {$0.body.x>=0.28 && $0.body.x<=0.3})
        var tracker=TrackTrackTracker()
        let id=try XCTUnwrap(tracker.seed([person(0),person(1,0.6,[0,1])],selectedID:0,time:0))
        let old=try XCTUnwrap(tracker.tracks.first {$0.id==id})
        let prediction=try XCTUnwrap(tracker.coastingTarget(id:id,time:0.1))
        tracker.keepCoasting(prediction)
        XCTAssertEqual(tracker.tracks.first {$0.id==id}?.feature,old.feature)
        tracker.recover(id:id,observation:found,prediction:prediction,protectedIDs:Set(tracker.tracks.filter {$0.id != id}.map(\.id)))
        XCTAssertEqual(tracker.tracks.count,2);XCTAssertEqual(tracker.tracks.first {$0.id==id}?.observation.id,4)
    }
}
