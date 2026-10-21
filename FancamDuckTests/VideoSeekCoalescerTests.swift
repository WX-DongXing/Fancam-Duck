import XCTest
import AVFoundation
@testable import FancamDuck

final class VideoSeekCoalescerTests:XCTestCase {
    @MainActor func testBurstKeepsOnlyLatestAndReleaseRemainsExact() {
        let seeker=VideoSeekCoalescer()
        var started:[Int]=[],completions:[@MainActor ()->Void]=[]
        func submit(_ frame:Int) {
            seeker.submit(.init(perform:{ done in started.append(frame);completions.append(done) },cancel:{}))
        }
        submit(0)
        for frame in 1...120 {submit(frame)}
        XCTAssertEqual(started,[0],"Decoder must finish its active seek instead of being interrupted at every touch")
        // The release request uses the same queue, so intermediate drags cannot overtake it.
        submit(121)
        completions[0]()
        XCTAssertEqual(started,[0,121])
        completions[1]()
        submit(122)
        XCTAssertEqual(started,[0,121,122])
    }
    @MainActor func testCancellationDropsPendingAndIgnoresLateCompletion() {
        let seeker=VideoSeekCoalescer()
        var started:[Int]=[],completions:[@MainActor ()->Void]=[],cancelled=0
        func submit(_ frame:Int) {
            seeker.submit(.init(perform:{ done in started.append(frame);completions.append(done) },cancel:{cancelled+=1}))
        }
        submit(1);submit(2);seeker.cancel()
        XCTAssertEqual(cancelled,1)
        submit(3);submit(4)
        completions[0]()
        XCTAssertEqual(started,[1,3],"A callback from the old project must not drain the new project's queue")
        completions[1]()
        XCTAssertEqual(started,[1,3,4])
        seeker.cancel()
    }
}

private final class ScrubRecordingPlayer:AVPlayer,@unchecked Sendable {
    struct Seek {let time:CMTime;let before:CMTime;let after:CMTime}
    var requests:[Seek]=[]
    var completions:[@Sendable (Bool)->Void]=[]
    var displayedTime=CMTime.zero
    override func currentTime()->CMTime {displayedTime}
    override func seek(to time:CMTime,toleranceBefore:CMTime,toleranceAfter:CMTime,completionHandler:@escaping @Sendable (Bool)->Void) {
        requests.append(.init(time:time,before:toleranceBefore,after:toleranceAfter))
        completions.append(completionHandler)
    }
    override func seek(to time:CMTime,toleranceBefore:CMTime,toleranceAfter:CMTime) {
        requests.append(.init(time:time,before:toleranceBefore,after:toleranceAfter))
    }
    func complete(_ index:Int) {displayedTime=requests[index].time;completions[index](true)}
}

extension VideoSeekCoalescerTests {
    @MainActor func testAnalyzedScrubDoesNotSeekHiddenPreviewAndSettlesExactly() async throws {
        let model=AppModel();model.startDemo();defer {model.project?.isDemo=true;model.goHome()}
        let body=DemoStage.body(index:1,time:0)
        model.selectTarget(body);model.hasCompletedTracking=true
        model.targetSamples=[.init(time:0,body:.init(x:0.1,y:0.1,width:0.15,height:0.7)),.init(time:58.2,body:.init(x:0.7,y:0.1,width:0.15,height:0.7))]
        model.beginComposition()
        for _ in 0..<400 {if !model.compositionBusy {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(model.compositionBusy)
        let openingCrop=try XCTUnwrap(model.compositionCrop)
        model.project?.isDemo=false
        let source=ScrubRecordingPlayer(playerItem:AVPlayerItem(url:URL(fileURLWithPath:"/nonexistent-scrub-fixture.mp4")))
        let preview=ScrubRecordingPlayer()
        model.player=source;model.previewPlayer=preview
        model.scrub(to:1)
        for time in 2...30 {model.scrub(to:Double(time))}
        XCTAssertEqual(source.requests.count,1)
        XCTAssertTrue(preview.requests.isEmpty,"Hidden CI/video composition must not be decoded for every drag position")
        XCTAssertEqual(model.currentTime,30)
        XCTAssertGreaterThan(source.requests[0].before.seconds,0)
        model.finishScrubbing()
        XCTAssertEqual(preview.requests.count,1)
        XCTAssertEqual(preview.requests[0].time.seconds,30,accuracy:0.001)
        source.complete(0)
        for _ in 0..<20 {if source.requests.count==2 {break};await Task.yield()}
        XCTAssertEqual(source.requests.count,2)
        XCTAssertEqual(source.requests[1].time.seconds,30,accuracy:0.001)
        XCTAssertEqual(source.requests[1].before,.zero)
        XCTAssertEqual(source.requests[1].after,.zero)
        source.complete(1)
        await Task.yield()
        XCTAssertTrue(model.compositionEditing)
        XCTAssertGreaterThan(try XCTUnwrap(model.compositionCrop).minX,openingCrop.minX+100,"Camera framing must follow the decoded timeline position")
        model.scrub(to:31)
        XCTAssertEqual(source.requests.count,3)
        model.project?.isDemo=true
        model.goHome()
        source.complete(2)
        await Task.yield()
        XCTAssertNil(model.compositionCrop,"A late seek callback must not restore the old project crop")
    }
}


extension VideoSeekCoalescerTests {
    @MainActor func testGeneratedPreviewScrubsOutputUsingTrimOffsetWithoutChangingSource() async throws {
        let model=AppModel();model.startDemo();defer {model.goHome()}
        model.project?.settings.start=10;model.project?.settings.end=30
        model.phase = .completed(nil)
        let source=ScrubRecordingPlayer()
        let output=ScrubRecordingPlayer(playerItem:AVPlayerItem(url:URL(fileURLWithPath:"/nonexistent-output.mp4")))
        model.player=source;model.previewPlayer=output
        let settings=model.project?.settings
        model.scrub(to:5)
        XCTAssertEqual(model.currentTime,10)
        XCTAssertEqual(output.requests[0].time.seconds,0,accuracy:0.001)
        model.scrub(to:25);model.finishScrubbing()
        output.complete(0)
        for _ in 0..<20 {if output.requests.count==2 {break};await Task.yield()}
        XCTAssertEqual(output.requests.count,2)
        XCTAssertEqual(output.requests[1].time.seconds,15,accuracy:0.001)
        XCTAssertEqual(output.requests[1].before,.zero)
        XCTAssertEqual(output.requests[1].after,.zero)
        XCTAssertEqual(model.currentTime,25)
        XCTAssertTrue(source.requests.isEmpty)
        XCTAssertEqual(model.project?.settings,settings)
        XCTAssertEqual(model.phase,.completed(nil))
        model.scrub(to:.nan)
        XCTAssertEqual(model.currentTime,25)
        output.complete(1)
        await Task.yield()
        model.seek(to:50)
        XCTAssertEqual(model.currentTime,30)
        XCTAssertEqual(output.requests.last?.time.seconds,20)
        model.goHome()
        output.complete(2)
        await Task.yield()
        XCTAssertEqual(model.route,.home)
    }
}
