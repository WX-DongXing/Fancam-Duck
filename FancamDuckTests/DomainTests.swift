import XCTest
@testable import FancamDuck

final class DomainTests: XCTestCase {
    func testOutputLabelsAreHeightFirstAndLegacyProjectsReframeSafely() throws {
        XCTAssertEqual(OutputAspectRatio.allCases.map(\.rawValue),["16:9","4:3","1:1"])
        XCTAssertEqual(OutputAspectRatio.portrait.value,9.0/16)
        XCTAssertEqual(OutputAspectRatio.classic.value,3.0/4)
        XCTAssertEqual(try JSONDecoder().decode(OutputAspectRatio.self,from:Data("\"9:16\"".utf8)),.portrait)
        var project=VideoProject.demo
        project.settings.resolution = .init(width:1920,height:1080)
        project.settings.compositionAnchor = .init(time:2,crop:.init(x:0.2,y:0.1,width:0.5,height:0.5))
        let center=project.settings.compositionAnchor!.crop.center
        project.normalizeOutputAspect()
        let crop=try XCTUnwrap(project.settings.compositionAnchor).crop
        XCTAssertEqual(crop.width*1920/(crop.height*1080),9.0/16,accuracy:0.00001)
        XCTAssertEqual(crop.center.x,center.x,accuracy:0.00001)
        XCTAssertEqual(crop.center.y,center.y,accuracy:0.00001)
        XCTAssertEqual(project.settings.compositionAnchor?.time,2)
        XCTAssertLessThanOrEqual(abs(Double(project.settings.resolution.height)-Double(project.settings.resolution.width)*16/9),2)
        let normalized=project;project.normalizeOutputAspect();XCTAssertEqual(project,normalized)
    }
    func testLandscapeResolutionsNeverUpscaleAndAreOrdered() {
        let sizes = OutputResolution.available(for: .init(width: 1920, height: 1080, duration: 60, frameRate: 30))
        XCTAssertEqual(sizes, [.init(width: 360, height: 640), .init(width: 540, height: 960), .init(width: 606, height: 1078)])
        XCTAssertFalse(sizes.contains(where: { $0.width == 1080 }))
        XCTAssertTrue(zip(sizes, sizes.dropFirst()).allSatisfy { $0.width < $1.width })
        XCTAssertTrue(sizes.allSatisfy { $0.width % 2 == 0 && $0.height % 2 == 0 })
    }
    func testEveryOutputAspectHasOrderedEvenNonUpscaledResolutions() {
        for source in [VideoMetadata(width:1920,height:1080,duration:1,frameRate:30),VideoMetadata(width:1080,height:1920,duration:1,frameRate:30)] {
            for aspect in OutputAspectRatio.allCases {
                let sizes=OutputResolution.available(for:source,aspect:aspect)
                XCTAssertFalse(sizes.isEmpty)
                XCTAssertTrue(zip(sizes,sizes.dropFirst()).allSatisfy {$0.width<$1.width})
                for size in sizes {
                    XCTAssertEqual(size.width%2,0);XCTAssertEqual(size.height%2,0)
                    XCTAssertLessThanOrEqual(Double(size.width),source.width);XCTAssertLessThanOrEqual(Double(size.height),source.height)
                    XCTAssertLessThanOrEqual(abs(Double(size.height)-Double(size.width)/aspect.value),2)
                }
            }
        }
    }
    func testFourKCanOffer1080Portrait() {
        XCTAssertTrue(OutputResolution.available(for: .init(width: 3840, height: 2160, duration: 60, frameRate: 60)).contains(.init(width: 1080, height: 1920)))
    }
    func testAspectFitPreservesBlackBarsForTouchMapping() {
        let rect = CropGeometry.aspectFit(video: CGSize(width: 1920, height: 1080), container: CGSize(width: 320, height: 400))
        XCTAssertEqual(rect.width, 320, accuracy: 0.01)
        XCTAssertEqual(rect.height, 180, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 110, accuracy: 0.01)
    }
    func testCropStaysInsideSourceAndPreservesPortraitAspect() {
        let source = CGSize(width: 1920, height: 1080)
        for x in [0.0, 0.5, 0.85] {
            let crop = CropGeometry.crop(source: source, target: .init(x: x, y: 0.05, width: 0.15, height: 0.9), personHeight: 0.75, offset: 0.3, protect: true)
            XCTAssertGreaterThanOrEqual(crop.minX, 0)
            XCTAssertLessThanOrEqual(crop.maxX, source.width + 0.001)
            XCTAssertLessThanOrEqual(crop.maxY, source.height + 0.001)
            XCTAssertEqual(crop.width / crop.height, 9.0 / 16, accuracy: 0.00001)
        }
    }
    func testBlockingIssueRequiresExplicitReselection() {
        let box = NormalizedRect(x: 0.3, y: 0.1, width: 0.2, height: 0.8)
        let phase = ProcessingPhase.blocked(.init(time: 22.4, message: "身份不确定", checkpoint: 0.56))
        XCTAssertFalse(ProcessingGate.canContinue(phase: phase, target: box, explicitlySelected: false))
        XCTAssertTrue(ProcessingGate.canContinue(phase: phase, target: box, explicitlySelected: true))
        XCTAssertFalse(ProcessingGate.canContinue(phase: .processing(progress: 0.5), target: box, explicitlySelected: true))
        XCTAssertFalse(ProcessingGate.canContinue(phase: phase, target: nil, explicitlySelected: true))
    }
    func testManualRectangleIsNormalizedAndClamped() {
        let rect = NormalizedRect.drawing(from: .init(x: 1.2, y: 0.8), to: .init(x: -0.2, y: 0.1))
        XCTAssertTrue(rect.isValid)
        XCTAssertEqual(rect.x, 0)
        XCTAssertEqual(rect.width, 1)
        XCTAssertFalse(NormalizedRect(x: .nan, y: 0, width: 1, height: 1).isValid)
    }
    func testProjectRoundTripsIncludingSelectionAndSettings() throws {
        var project = VideoProject.demo
        project.target = .init(x: 0.2, y: 0.1, width: 0.2, height: 0.8)
        project.targetTime = 3.4
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(VideoProject.self, from: data), project)
    }
}
