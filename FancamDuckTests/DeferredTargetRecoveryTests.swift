import XCTest
@testable import FancamDuck

final class DeferredTargetRecoveryTests:XCTestCase {
    private let body=NormalizedRect(x:0.2,y:0.1,width:0.2,height:0.7)
    private func person(_ id:Int,_ feature:[Float],x:Double=0.2) -> PersonObservation {
        .init(id:id,body:.init(x:x,y:0.1,width:0.2,height:0.7),confidence:0.9,embedding:Appearance.normalized(feature))
    }
    func testDeferredFramesStayPendingUntilExplicitlyResolved() {
        var recovery=DeferredTargetRecovery()
        recovery.record(2);recovery.record(1);recovery.record(1.00000001)
        XCTAssertEqual(recovery.orderedTimes.count,2)
        recovery.resolve(1)
        XCTAssertEqual(recovery.orderedTimes,[2])
        XCTAssertNil(DeferredTargetRecovery.candidate([],gallery:[[1,0]]))
        XCTAssertFalse(recovery.isEmpty,"No interpolated rectangle may silently resolve a missing frame")
    }
    func testLaterKnownAppearanceCanRecoverPreviouslyUnmatchedFrame() {
        let turned=person(1,[0.5,0.866])
        XCTAssertNil(DeferredTargetRecovery.candidate([turned],gallery:[[1,0]]))
        XCTAssertEqual(DeferredTargetRecovery.candidate([turned],gallery:[[1,0],turned.embedding])?.id,1)
    }
    func testAppearanceConflictDoesNotSelectNearestPerson() {
        let first=person(1,[1,0]),second=person(2,[1,0],x:0.55)
        XCTAssertNil(DeferredTargetRecovery.candidate([first,second],gallery:[[1,0]]))
        XCTAssertNil(DeferredTargetRecovery.candidate([person(3,[0,1])],gallery:[[1,0]]))
        XCTAssertNil(DeferredTargetRecovery.candidate([person(4,[])],gallery:[[1,0]]))
    }
    func testDuplicateDetectionIDIsNotACompetingIdentity() {
        let target=person(1,[1,0])
        XCTAssertEqual(DeferredTargetRecovery.candidate([target,target],gallery:[[1,0]])?.id,1)
    }
    func testReacquisitionNeedsTwoConsecutiveConsistentFrames() {
        var confirmation=DeferredTargetRecovery.Confirmation()
        XCTAssertNil(confirmation.accept(person(1,[1,0])))
        XCTAssertNil(confirmation.accept(nil))
        XCTAssertNil(confirmation.accept(person(2,[1,0])))
        XCTAssertNotNil(confirmation.accept(person(3,[1,0],x:0.21)))
        XCTAssertNil(confirmation.accept(person(4,[0,1],x:0.7)))
    }
    func testReferenceUsesBothConfirmedSidesButDoesNotCommitTrajectory() throws {
        let anchors=[TargetSample(time:0,body:body),TargetSample(time:2,body:.init(x:0.6,y:0.1,width:0.2,height:0.7))]
        let reference=try XCTUnwrap(DeferredTargetRecovery.reference(at:1,anchors:anchors))
        XCTAssertEqual(reference.body.x,0.4,accuracy:0.001)
        XCTAssertEqual(reference.estimated,true)
        XCTAssertNil(DeferredTargetRecovery.reference(at:1,anchors:[]))
        XCTAssertEqual(DeferredTargetRecovery.reference(at:3,anchors:anchors)?.body,anchors.last?.body)
    }
    func testKnownOtherPersonCannotBeReacquiredOrRecoveredWithNewDetectionID() {
        let other=person(2,[1,0])
        XCTAssertNil(DeferredTargetRecovery.candidate([other],gallery:[[1,0]],unavailable:[other]))
        let retry=person(40000,[1,0],x:0.21)
        XCTAssertNil(DeferredTargetRecovery.candidate([retry],gallery:[[1,0]],unavailable:[other]))
    }
    func testNearThresholdCompetitorStillPreventsUniqueIdentityClaim() {
        let first=person(1,[0.71,sqrt(1-0.71*0.71)])
        let second=person(2,[0.67,sqrt(1-0.67*0.67)])
        XCTAssertNil(DeferredTargetRecovery.candidate([first,second],gallery:[[1,0]]))
    }
    func testRetryIDsRemainUniqueAcrossMultipleManualCorrections() {
        let original=DetectionBatch(primary:[person(0,[1,0])],relaxed:[])
        let retry=DetectionBatch(primary:[person(0,[0,1])],relaxed:[])
        let once=DeferredTargetRecovery.mergingRetry(retry,into:original)
        let twice=DeferredTargetRecovery.mergingRetry(retry,into:once)
        XCTAssertEqual(Set(twice.primary.map(\.id)).count,3)
        XCTAssertEqual(twice.primary.count,3)
    }
    func testNonFiniteAppearanceDoesNotEstablishIdentity() {
        let broken=PersonObservation(id:1,body:body,confidence:0.9,embedding:[.nan,0])
        XCTAssertNil(DeferredTargetRecovery.candidate([broken],gallery:[[1,0]]))
    }
    func testRetryRejectsAppearanceMatchFarFromBothAnchorPrediction() {
        let target=person(1,[1,0],x:0.78)
        XCTAssertNil(DeferredTargetRecovery.candidate([target],gallery:[[1,0]],reference:.init(time:1,body:body)))
    }
}
