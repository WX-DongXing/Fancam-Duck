import XCTest
import CoreImage
import CoreVideo
@testable import FancamDuck

final class AnalysisFrameReaderTests:XCTestCase {
    func testCancelledSequentialReadReturnsCancellation() async throws {
        let source=try TestVideoFixture.people()
        let reader=try await AnalysisFrameReader(source:source,start:0,end:0.4)
        defer {reader.cancel()}
        let task=Task {try await reader.imageCancellable(at:0.3)}
        task.cancel()
        do {_ = try await task.value;XCTFail("Cancelled read must throw")}
        catch is CancellationError {}
    }
    func testDesktopSequentialDecodeCrossesFormerStalledRange() async throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_REVERSE_VALIDATION"]=="1" else {throw XCTSkip("Local desktop reverse decode opt-in")}
        let projects=try await ProjectStore.shared.projects()
        let project=try XCTUnwrap(projects.first {$0.metadata.width==3840 && abs($0.metadata.duration-37.92)<0.01})
        let source=try XCTUnwrap(ProjectStore.shared.sourceURL(for:project))
        let began=Date()
        var cursor=30.68578616352201,count=0
        let end=4.690314465408805
        var times:[Double]=[]
        while cursor>end+0.001 {cursor=max(end,cursor-0.1);times.append(cursor)}
        let reader=try await AnalysisFrameReader(source:source,start:0,end:30.68578616352201)
        defer {reader.cancel()}
        for time in times.reversed() {
            let image=try await reader.imageCancellable(at:time)
            XCTAssertEqual(image.extent.width,3840);count += 1
        }
        XCTAssertEqual(cursor,end,accuracy:0.001)
        XCTAssertGreaterThanOrEqual(count,260)
        print("REVERSE_DESKTOP frames=\(count) seconds=\(Date().timeIntervalSince(began)) end=\(cursor)")
    }
}
