import XCTest
@testable import FancamDuck

final class DesktopReaderParityTests:XCTestCase {
    func testSequentialDecoderMatchesRandomAccessOnDesktopVideo() async throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_DESKTOP_VALIDATION"] == "1" else { throw XCTSkip("Local desktop video opt-in") }
        let projects=try await ProjectStore.shared.projects()
        let project=try XCTUnwrap(projects.first { $0.metadata.width==3840 && abs($0.metadata.duration-37.92)<0.1 })
        let source=try XCTUnwrap(ProjectStore.shared.sourceURL(for:project))
        let engine=try CoreMLPeopleModels()
        let reader=try await AnalysisFrameReader(source:source,start:0,end:14)
        for time in [0.0,11.4,13.7] {
            let original=try engine.detect(await engine.image(source:source,time:time),features:true).primary
            let sequential=try engine.detect(reader.image(at:time),features:true).primary
            let a=try XCTUnwrap(original.filter { $0.confidence>0.3 }.min { abs($0.body.center.x-0.46)<abs($1.body.center.x-0.46) })
            let b=try XCTUnwrap(sequential.max { $0.body.iou(a.body)<$1.body.iou(a.body) })
            let distance=Appearance.distance(a.embedding,b.embedding)
            print("DECODER_PARITY time=\(time) iou=\(a.body.iou(b.body)) scoreDifference=\(abs(a.confidence-b.confidence)) reidDistance=\(distance)")
            XCTAssertGreaterThan(a.body.iou(b.body),0.75)
            XCTAssertLessThan(distance,0.2)
        }
        reader.cancel()
    }
}
