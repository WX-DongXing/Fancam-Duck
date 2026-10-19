import XCTest
@testable import FancamDuck

/// Private desktop footage stays local and is excluded from version control.
final class DesktopOcclusionTests:XCTestCase {
    func testMaskedDesktopDancerRecoversWithoutManualSelection() async throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_OCCLUSION_VALIDATION"]=="1" else { throw XCTSkip("Opt-in private video occlusion validation") }
        let source=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"desktop-occlusion",withExtension:"mp4"))
        let metadata=try await MediaService.shared.metadata(url:source)
        let pipeline=CoreMLTrackingPipeline()
        let people=try await pipeline.detections(source:source,time:0,region:nil)
        let selected=try XCTUnwrap(people.min { abs($0.body.center.x-0.455)<abs($1.body.center.x-0.455) })
        var project=VideoProject(title:"Controlled desktop occlusion",metadata:metadata,settings:EditSettings())
        project.target=selected.body;project.settings.end=4;project.settings.resolution = .init(width:360,height:640)
        let start=Date()
        let result=try await pipeline.analyze(source:source,project:project) { _ in }
        print("OCCLUSION_RESULT seconds=\(Date().timeIntervalSince(start)) issue=\(String(describing:result.issue)) estimated=\(result.samples.filter {$0.estimated==true}.count)")
        XCTAssertNil(result.issue,"0.5 second controlled occlusion should recover automatically")
        XCTAssertGreaterThan(result.samples.filter {$0.estimated==true}.count,0,"The fixture must actually exercise prediction")
        XCTAssertEqual(result.samples.last?.time ?? -1,4,accuracy:0.001)
        XCTAssertEqual(Set(result.samples.map(\.trackID)).count,1)
        let truthURL=Bundle(for:Self.self).url(forResource:"desktop-occlusion-truth",withExtension:"json")
        if let truthURL {
            let truth=try JSONDecoder().decode([TargetSample].self,from:Data(contentsOf:truthURL))
            for sample in result.samples where sample.time>2.4 {
                let expected=try XCTUnwrap(truth.min { abs($0.time-sample.time)<abs($1.time-sample.time) })
                XCTAssertLessThan(abs(sample.body.center.x-expected.body.center.x),0.04,"Must recover the same black-clothed dancer")
            }
        }
        let data=try JSONEncoder().encode(result.samples)
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");attachment.name="Occlusion recovered trajectory";attachment.lifetime = .keepAlways;add(attachment)
        let output=try await VideoExporter().exportMovingCrop(source:source,project:project,samples:result.samples)
        let video=XCTAttachment(contentsOfFile:output);video.name="Controlled occlusion automatic recovery";video.lifetime = .keepAlways;add(video)
        let exported=try await MediaService.shared.metadata(url:output)
        XCTAssertEqual(exported.duration,4,accuracy:0.05)
        try? FileManager.default.removeItem(at:output)
    }
}
