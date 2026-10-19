import XCTest
import AVFoundation
@testable import FancamDuck

final class RealTrackingTests: XCTestCase {
    func testRealPeopleInferenceTrackingAndMovingExport() async throws {
        let url = try TestVideoFixture.people()
        let pipeline = CoreMLTrackingPipeline()
        let clock = ContinuousClock(); let begin = clock.now
        let people = try await pipeline.detections(source: url, time: 0, region: nil)
        print("DETECTIONS count=\(people.count) scores=\(people.map(\.confidence))")
        XCTAssertGreaterThanOrEqual(people.count, 2)
        let target = try XCTUnwrap(people.max { $0.body.height < $1.body.height })
        let metadata = try await MediaService.shared.metadata(url: url)
        var project = VideoProject(title: "Real people", metadata: metadata, settings: EditSettings())
        project.settings.end = 0.7
        project.settings.resolution = .init(width: 180,height:320)
        project.target = target.body
        let result = try await pipeline.analyze(source: url, project: project) { _ in }
        XCTAssertNil(result.issue, "Clear one-second real footage should track continuously")
        XCTAssertGreaterThanOrEqual(result.samples.count, 8)
        XCTAssertEqual(result.samples.first!.time, 0, accuracy: 0.001)
        XCTAssertEqual(result.samples.last!.time, 0.7, accuracy: 0.001)
        XCTAssertTrue(result.samples.contains { $0.body != target.body })
        let output = try await VideoExporter().exportMovingCrop(source: url, project: project, samples: result.samples)
        let exported = try await MediaService.shared.metadata(url: output)
        XCTAssertEqual(exported.width, 180); XCTAssertEqual(exported.height,320)
        XCTAssertEqual(exported.duration,0.7,accuracy:1/30)
        let elapsed = begin.duration(to: clock.now)
        print("REAL_PIPELINE people=\(people.count) samples=\(result.samples.count) elapsed=\(elapsed) output=\(output.path)")
        let attachment = XCTAttachment(contentsOfFile: output); attachment.name = "Actual people moving crop"; attachment.lifetime = .keepAlways; add(attachment)
        try? FileManager.default.removeItem(at: output)
    }
    @MainActor func testRealEditorSelectionToExportPage() async throws {
        let fixture = try TestVideoFixture.people()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = ProjectStore(directory:directory)
        let source = try await store.importFile(fixture)
        var project = VideoProject(title:"Editor integration",sourceFileName:source.lastPathComponent,metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        project.settings.end = 0.7; project.settings.resolution = .init(width:180,height:320)
        let model = AppModel(store:store)
        model.open(project)
        for _ in 0..<200 where model.observations.isEmpty && model.errorMessage == nil { try await Task.sleep(for:.milliseconds(25)) }
        let person = try XCTUnwrap(model.observations.max { $0.body.height < $1.body.height })
        model.selectTarget(person.body); XCTAssertTrue(model.canConfirm)
        model.confirmProcessing()
        for _ in 0..<400 where model.route != .export && model.errorMessage == nil && model.phase.issue == nil { try await Task.sleep(for:.milliseconds(25)) }
        XCTAssertNil(model.errorMessage); XCTAssertNil(model.phase.issue)
        XCTAssertEqual(model.route,.export)
        XCTAssertNotNil(model.previewPlayer?.currentItem?.videoComposition)
        XCTAssertNotNil(model.exportPoster,"Ready previews must provide a correctly composed export poster")
        model.export()
        for _ in 0..<200 where model.outputURL == nil && model.errorMessage == nil { try await Task.sleep(for:.milliseconds(25)) }
        XCTAssertNil(model.errorMessage)
        let output = try XCTUnwrap(model.outputURL)
        try? FileManager.default.removeItem(at:output)
        model.goHome()
    }
    func testRealLowConfidenceBlocksAndIncompleteTrajectoryCannotExport() async throws {
        let url = try TestVideoFixture.people()
        let pipeline = CoreMLTrackingPipeline()
        let people = try await pipeline.detections(source: url, time: 0, region: nil)
        let chosen = try XCTUnwrap(people.max { $0.body.height < $1.body.height })
        var project = VideoProject(title: "Blocking", metadata: try await MediaService.shared.metadata(url:url), settings: EditSettings())
        project.settings.end = 1; project.target = chosen.body
        let result = try await pipeline.analyze(source:url, project:project) { _ in }
        let issue = try XCTUnwrap(result.issue)
        XCTAssertLessThan(result.samples.last!.time, issue.time)
        XCTAssertLessThan(issue.checkpoint,1)
        do {
            _ = try await VideoExporter().exportMovingCrop(source:url, project:project, samples:result.samples)
            XCTFail("Incomplete trajectory must be rejected")
        } catch TrackingError.invalidTrajectory {}
        // Re-select at a clear source frame and cover both the uncertain gap and remaining segment.
        let candidates = try await pipeline.detections(source:url,time:issue.time,region:chosen.body)
        if let correction = candidates.max(by: { $0.body.iou(chosen.body) < $1.body.iou(chosen.body) }) {
            project.target = correction.body; project.targetTime = issue.time
            let resumed = try await pipeline.analyze(source:url,project:project) { _ in }
            XCTAssertTrue(resumed.samples.contains { abs($0.time) < 0.001 })
            XCTAssertTrue(resumed.samples.contains { abs($0.time-issue.time) < 0.001 })
            print("REAL_RESUME correctedAt=\(issue.time) remainingIssue=\(String(describing: resumed.issue))")
        } else { XCTFail("Local re-detection should offer a correction candidate") }
    }
    func testChangedRangeDoesNotReuseCancelledTrackingSession() async throws {
        let source=try TestVideoFixture.people()
        let pipeline=CoreMLTrackingPipeline()
        let people=try await pipeline.detections(source:source,time:0,region:nil)
        let chosen=try XCTUnwrap(people.max {$0.body.height<$1.body.height})
        var p=VideoProject(title:"Checkpoint configuration",metadata:try await MediaService.shared.metadata(url:source),settings:EditSettings())
        p.target=chosen.body;p.settings.end=0.7
        let initial=p
        let interrupted=Task {
            try await pipeline.analyze(source:source,project:initial) { update in
                if update.sample.time>=0.2 { withUnsafeCurrentTask {$0?.cancel()} }
            }
        }
        do { _=try await interrupted.value;XCTFail("Expected a cancelled checkpoint") }
        catch is CancellationError {}
        // Keep the same identity seed: this regression isolates stale trim state,
        // rather than introducing a different appearance gallery halfway through motion.
        p.settings.end=0.5
        let result=try await pipeline.analyze(source:source,project:p) {_ in}
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.samples.first?.time ?? -1,0,accuracy:0.001)
        XCTAssertEqual(result.samples.last?.time ?? -1,0.5,accuracy:0.001)
        XCTAssertTrue(result.samples.allSatisfy {$0.time>=0 && $0.time<=0.501},"Samples from the old trim must not survive")
    }
    func testTrackTrackKeepsAppearanceAcrossCrossingAndLowConfidence() {
        func observation(_ id: Int, _ x: Double, _ embedding: [Float], _ confidence: Float = 0.9) -> PersonObservation {
            .init(id:id,body:.init(x:x,y:0.1,width:0.3,height:0.8),confidence:confidence,embedding:embedding)
        }
        var tracker = TrackTrackTracker()
        let id = tracker.seed([observation(0,0.2,[1,0]),observation(1,0.5,[0,1])],selectedID:0,time:0)!
        let next = [observation(9,0.3,[1,0]),observation(8,0.4,[0,1])]
        XCTAssertEqual(tracker.update(.init(primary:next,relaxed:next),time:0.1)[id]?.id,9)
        let low = [observation(5,0.4,[1,0],0.4),observation(6,0.3,[0,1])]
        XCTAssertEqual(tracker.update(.init(primary:low,relaxed:low),time:0.2)[id]?.id,5)
    }
}
