import XCTest
@testable import FancamDuck

/// Explicit local benchmark: identical source, target, 10Hz samples and output settings.
final class DesktopPerformanceTests:XCTestCase {
    func testFullDesktopBenchmark() async throws {
        let env=ProcessInfo.processInfo.environment
        guard env["FANCAM_DUCK_DESKTOP_BENCHMARK"]=="1" else { throw XCTSkip("Opt-in full private desktop benchmark") }
        let label=env["FANCAM_DUCK_BENCHMARK_LABEL"] ?? "run"
        let records=try await ProjectStore.shared.projects()
        let saved=try XCTUnwrap(records.first {$0.metadata.width==3840 && abs($0.metadata.duration-37.92)<0.01})
        let source=try XCTUnwrap(ProjectStore.shared.sourceURL(for:saved))
        let pipeline=CoreMLTrackingPipeline(reuseBuffers:env["FANCAM_DUCK_REUSE_BUFFERS"] != "0",previewInterval:Double(env["FANCAM_DUCK_PREVIEW_INTERVAL"] ?? "0.2") ?? 0.2)
        let people=try await pipeline.detections(source:source,time:0,region:nil)
        let target=try XCTUnwrap(people.filter {$0.confidence>=0.3}.min {abs($0.body.center.x-0.455)<abs($1.body.center.x-0.455)})
        var p=VideoProject(title:"Desktop benchmark",metadata:saved.metadata,settings:EditSettings())
        p.settings.end=37.92;p.settings.resolution = .init(width:1080,height:1920);p.target=target.body
        let began=Date()
        let result=try await pipeline.analyze(source:source,project:p) { update in
            if Int((update.sample.time*10).rounded())%50==0 { print("BENCHMARK_PROGRESS source=\(update.sample.time)") }
        }
        let analysis=Date().timeIntervalSince(began)
        XCTAssertNil(result.issue);XCTAssertEqual(result.samples.first?.time,0)
        XCTAssertEqual(result.samples.last?.time ?? -1,37.92,accuracy:0.001)
        try VideoExporter.validateTrajectory(result.samples,project:p)
        let planStart=Date(),plan=CropPlan.make(samples:result.samples,source:p.metadata.size,settings:p.settings)
        let planSeconds=Date().timeIntervalSince(planStart)
        let exportStart=Date()
        let output=try await VideoExporter().exportMovingCrop(source:source,project:p,samples:result.samples)
        let exportSeconds=Date().timeIntervalSince(exportStart)
        let metadata=try await MediaService.shared.metadata(url:output)
        XCTAssertEqual(metadata.width,1080);XCTAssertEqual(metadata.height,1920);XCTAssertEqual(metadata.frameRate,25,accuracy:0.01)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("FancamDuck-benchmark-"+label)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(result.samples).write(to:root.appendingPathComponent("trajectory.json"))
        try JSONEncoder().encode(plan).write(to:root.appendingPathComponent("camera.json"))
        try JSONEncoder().encode(CropPlan.renderFrames(plan,frameRate:25)).write(to:root.appendingPathComponent("rendered-camera.json"))
        struct Report:Codable {let label:String;let analysisSeconds:Double;let exportSeconds:Double;let planSeconds:Double;let samples:Int;let metrics:CoreMLPeopleModels.Metrics?;let source:VideoMetadata;let output:VideoMetadata}
        let report=Report(label:label,analysisSeconds:analysis,exportSeconds:exportSeconds,planSeconds:planSeconds,samples:result.samples.count,metrics:await pipeline.performanceMetrics(),source:p.metadata,output:metadata)
        let data=try JSONEncoder().encode(report)
        try data.write(to:root.appendingPathComponent("report.json"))
        let destination=root.appendingPathComponent("output.mp4")
        try? FileManager.default.removeItem(at:destination)
        try FileManager.default.moveItem(at:output,to:destination)
        print("DESKTOP_BENCHMARK \(String(decoding:data,as:UTF8.self)) path=\(root.path)")
    }
}
