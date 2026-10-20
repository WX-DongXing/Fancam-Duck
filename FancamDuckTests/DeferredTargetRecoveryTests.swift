import XCTest
@testable import FancamDuck

final class DeferredTargetRecoveryTests:XCTestCase {
    private let body=NormalizedRect(x:0.2,y:0.1,width:0.2,height:0.7)
    private func person(_ id:Int,_ feature:[Float],x:Double=0.2) -> PersonObservation {
        .init(id:id,body:.init(x:x,y:0.1,width:0.2,height:0.7),confidence:0.9,embedding:Appearance.normalized(feature))
    }
    func testConcretePipelineRestoresAndReadsItsDetectionCache() async {
        let pipeline=CoreMLTrackingPipeline()
        let source=URL(fileURLWithPath:"/tmp/cache-roundtrip.mp4")
        let observation=PersonObservation(id:1,body:.init(x:0.2,y:0.1,width:0.2,height:0.7),confidence:0.9,embedding:[1,0])
        await pipeline.restorePeople([1000:.init(primary:[observation],relaxed:[])],source:source)
        let restored=await pipeline.cachedPeople(source:source)
        XCTAssertEqual(restored[1000]?.primary.first?.id,1)
        let other=await pipeline.cachedPeople(source:URL(fileURLWithPath:"/tmp/other.mp4"))
        XCTAssertTrue(other.isEmpty)
    }
    func testLocalRetryBoundariesBridgeOnlyABoundedConfirmedGap() {
        var recovery=DeferredTargetRecovery()
        [0.1,0.2,0.3].forEach {recovery.record($0)}
        let observations=[0.4,0.5].map {time in (Int((time*10000).rounded()),DetectionBatch(primary:[person(1,[1,0])],relaxed:[]))}
        let batches=Dictionary(uniqueKeysWithValues:observations)
        let anchors=[0.0,0.4,0.5].map {TargetSample(time:$0,body:body)}
        let bridged=recovery.boundedBridges(anchors:anchors,batches:batches)
        XCTAssertEqual(bridged.map(\.time),[0.1,0.2,0.3])
        XCTAssertTrue(bridged.allSatisfy {$0.estimated == true})
        XCTAssertEqual(recovery.orderedTimes.count,3,"Bridge planning does not mutate unresolved state")
        XCTAssertTrue(recovery.boundedBridges(anchors:Array(anchors.prefix(2)),batches:batches).isEmpty)
        XCTAssertTrue(recovery.boundedBridges(anchors:anchors,batches:[:]).isEmpty)
        let estimated=anchors.map {TargetSample(time:$0.time,body:body,estimated:true)}
        XCTAssertTrue(recovery.boundedBridges(anchors:estimated,batches:batches).isEmpty)
        var long=DeferredTargetRecovery()
        long.record(0.1);long.record(0.2)
        let far=[0.0,1.3,1.4].map {TargetSample(time:$0,body:body)}
        XCTAssertTrue(long.boundedBridges(anchors:far,batches:batches).isEmpty)
    }
    func testSmallTargetDoesNotCompeteWithPersonTwoBodyWidthsAway() {
        let box=NormalizedRect(x:0.28,y:0.35,width:0.05,height:0.27)
        let target=PersonObservation(id:1,body:box,confidence:0.8,embedding:[1,0])
        let distant=PersonObservation(id:2,body:.init(x:0.38,y:0.35,width:0.03,height:0.3),confidence:0.8,embedding:[1,0])
        XCTAssertEqual(DeferredTargetRecovery.candidate([target,distant],gallery:[[1,0]],reference:.init(time:0,body:box))?.id,1)
        XCTAssertNil(DeferredTargetRecovery.candidate([distant],gallery:[[1,0]],reference:.init(time:0,body:box)))
    }
    func testHumanBoxUsesVisibleCenteredFragmentInsteadOfLargerOccluder() {
        let human=NormalizedRect(x:0.293,y:0.36,width:0.07,height:0.267)
        let fragment=PersonObservation(id:1,body:.init(x:0.311,y:0.35,width:0.038,height:0.295),confidence:0.3496,embedding:Appearance.normalized([0.65,0.76]))
        let occluder=PersonObservation(id:2,body:.init(x:0.237,y:0.25,width:0.114,height:0.475),confidence:0.86,embedding:Appearance.normalized([0.55,0.835]))
        XCTAssertEqual(DeferredTargetRecovery.manualSeed(box:human,observations:[occluder,fragment],gallery:[[1,0]])?.id,1)
    }
    func testContainedPartialPoseRequiresMatchingJointsAcrossTheBody() {
        let points=[0.2,0.35,0.5,0.7].map {PosePoint(x:0.32,y:$0,confidence:0.8)}
        let whole=PersonObservation(id:1,body:.init(x:0.2,y:0.1,width:0.2,height:0.7),confidence:0.9,keypoints:points,embedding:[1,0])
        let partial=PersonObservation(id:2,body:.init(x:0.3,y:0.15,width:0.06,height:0.6),confidence:0.6,keypoints:points,embedding:[1,0])
        XCTAssertLessThan(whole.body.iou(partial.body),0.4)
        XCTAssertTrue(PersonIdentityGate.samePose(whole,partial))
        let other=PersonObservation(id:3,body:partial.body,confidence:0.9,keypoints:points.map {PosePoint(x:$0.x+0.04,y:$0.y,confidence:0.8)},embedding:[1,0])
        XCTAssertFalse(PersonIdentityGate.samePose(whole,other),"Overlapping similar people with different joints remain distinct")
        let sparse=PersonObservation(id:4,body:partial.body,confidence:0.9,keypoints:Array(points.prefix(2)),embedding:[1,0])
        XCTAssertFalse(PersonIdentityGate.samePose(whole,sparse))
    }
    func testHumanBoxCanVerifyAPartialPoseBelowAutomaticRecoveryThreshold() {
        let partial=PersonObservation(id:7,body:body,confidence:0.30,embedding:Appearance.normalized([0.6,0.8]))
        XCTAssertNil(DeferredTargetRecovery.candidate([partial],gallery:[[1,0]]))
        XCTAssertEqual(DeferredTargetRecovery.manualSeed(box:body,observations:[partial],gallery:[[1,0]])?.id,7)
        let wrong=PersonObservation(id:8,body:body,confidence:0.9,embedding:[0,1])
        XCTAssertNil(DeferredTargetRecovery.manualSeed(box:body,observations:[wrong],gallery:[[1,0]]))
        let competitor=PersonObservation(id:9,body:.init(x:0.23,y:0.1,width:0.2,height:0.7),confidence:0.9,embedding:partial.embedding)
        XCTAssertNil(DeferredTargetRecovery.manualSeed(box:body,observations:[partial,competitor],gallery:[[1,0]]))
    }
    func testManualCorrectionRestartsWholeFirstGapWithConfirmedBoundaries() {
        var recovery=DeferredTargetRecovery()
        for time in [0.2,0.3,0.4,1.0,1.1] {recovery.record(time)}
        let anchors=[0.0,0.1,0.5,0.6,0.9,1.2].map {TargetSample(time:$0,body:body)}
        XCTAssertEqual(recovery.restartRange(around:0.2,manualTime:0.3,anchors:anchors),0.0...0.6)
        XCTAssertEqual(recovery.restartRange(around:1.0,manualTime:1.15,anchors:anchors),0.6...1.2)
        XCTAssertEqual(recovery.orderedTimes.count,5,"Planning a re-track must not mark missing frames resolved")
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
    func testManualPartialBoxReusesVerifiedFullBodyPose() {
        let box=NormalizedRect(x:0.30,y:0.2,width:0.1,height:0.25)
        let body=NormalizedRect(x:0.28,y:0.18,width:0.14,height:0.6)
        let target=PersonObservation(id:1,body:body,confidence:0.9,embedding:[1,0])
        let other=PersonObservation(id:2,body:.init(x:0.55,y:0.18,width:0.14,height:0.6),confidence:0.9,embedding:[1,0])
        XCTAssertLessThan(box.iou(body),0.8)
        XCTAssertEqual(DeferredTargetRecovery.manualSeed(box:box,observations:[target,other],gallery:[[1,0]])?.id,1)
        let foreign=PersonObservation(id:3,body:body,confidence:0.9,embedding:[0,1])
        XCTAssertNil(DeferredTargetRecovery.manualSeed(box:box,observations:[foreign],gallery:[[1,0]]),"An overlapping occluder must not supply the target's appearance")
    }

    func testRestartIncludesMissingFramesAfterTheHumanAnchor() {
        var recovery=DeferredTargetRecovery()
        for t in [1.0,1.1,1.3,1.4,1.6,1.7,1.9,2.0,9.0] {recovery.record(t)}
        let box=NormalizedRect(x:0.3,y:0.2,width:0.1,height:0.5)
        let anchors=[0.8,0.9,1.2,1.5,1.8,2.1,2.2,8.9,9.1].map {TargetSample(time:$0,body:box)}
        XCTAssertEqual(recovery.restartRange(around:1,manualTime:1.8,anchors:anchors),0.8...2.2)
    }

    func testManualSeedDoesNotLeaveTheSamePersonAsAProtectedBystander() {
        let box=NormalizedRect(x:0.30,y:0.2,width:0.1,height:0.25)
        let target=PersonObservation(id:1,body:.init(x:0.28,y:0.18,width:0.14,height:0.6),confidence:0.9,embedding:[1,0])
        XCTAssertTrue(DeferredTargetRecovery.duplicatesManualSeed(target,box:box,embedding:[1,0]))
        var foreign=target;foreign.embedding=[0,1]
        XCTAssertFalse(DeferredTargetRecovery.duplicatesManualSeed(foreign,box:box,embedding:[1,0]))
        let neighbor=PersonObservation(id:2,body:.init(x:0.55,y:0.18,width:0.14,height:0.6),confidence:0.9,embedding:[1,0])
        XCTAssertFalse(DeferredTargetRecovery.duplicatesManualSeed(neighbor,box:box,embedding:[1,0]))
    }

    func testOneIsolatedDetectionDoesNotSplitTheRecoveryInterval() {
        var recovery=DeferredTargetRecovery()
        for t in [1.0,1.1,1.3,1.4,8.0] {recovery.record(t)}
        let box=NormalizedRect(x:0.3,y:0.2,width:0.1,height:0.5)
        let anchors=[0.8,0.9,1.2,1.5,1.6,7.9,8.1].map {TargetSample(time:$0,body:box)}
        XCTAssertEqual(recovery.restartRange(around:1,manualTime:1,anchors:anchors),0.8...1.6)
    }

    func testLocalAndFullFrameSeedDetectionsCannotOwnTheSamePersonTwice() {
        let selected=PersonObservation(id:1,body:.init(x:0.3,y:0.2,width:0.1,height:0.3),confidence:0.9,embedding:[1,0])
        let duplicate=PersonObservation(id:2,body:.init(x:0.28,y:0.18,width:0.14,height:0.6),confidence:0.9,embedding:[1,0])
        let neighbor=PersonObservation(id:3,body:.init(x:0.55,y:0.18,width:0.14,height:0.6),confidence:0.9,embedding:[1,0])
        let seed=DeferredTargetRecovery.seedPeople([selected,duplicate,neighbor],selected:selected)
        XCTAssertEqual(seed.map(\.id),[1,3])
        var tracker=TrackTrackTracker()
        XCTAssertNotNil(tracker.seed(seed,selectedID:1,time:0))
        XCTAssertEqual(tracker.tracks.count,2)
    }

}
