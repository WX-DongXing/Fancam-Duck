import XCTest
@testable import FancamDuck

final class PerformanceReviewTests:XCTestCase {
    func testPrimaryBodyLookupMatchesLongTrajectoryWithoutMaterializingFrames() {
        var project=VideoProject.demo
        let samples=(0...6000).map {index in
            TargetSample(time:Double(index)/6,body:.init(x:0.15+sin(Double(index)*0.1)*0.1,y:0.2,width:0.2,height:0.6))
        }
        project.target=samples[0].body;project.targetTime=0
        for index in stride(from:0,to:6000,by:37) {
            let time=(samples[index].time+samples[index+1].time)/2
            let actual=RedactionPolicy.primaryBody(project:project,time:time,samples:samples)
            XCTAssertEqual(actual?.x ?? -1,(samples[index].body.x+samples[index+1].body.x)/2,accuracy:0.000000001)
            XCTAssertEqual(actual?.width,0.2)
        }
        XCTAssertEqual(RedactionPolicy.primaryBody(project:project,time:-0.0005,samples:samples),samples.first?.body)
        XCTAssertEqual(RedactionPolicy.primaryBody(project:project,time:1000.0005,samples:samples),samples.last?.body)
        XCTAssertNil(RedactionPolicy.primaryBody(project:project,time:1001,samples:samples))
        XCTAssertNil(RedactionPolicy.primaryBody(project:project,time:.nan,samples:samples))
        XCTAssertEqual(RedactionPolicy.primaryBody(project:project,time:0,samples:[]),project.target)
    }
    func testCancelledCameraCalculationDoesNotProducePartialTrajectory() async {
        let samples=(0...3000).map {index in
            TargetSample(time:Double(index)/6,body:.init(x:0.2+sin(Double(index)*0.1)*0.1,y:0.2,width:0.2,height:0.6))
        }
        var settings=EditSettings()
        settings.end=500
        settings.compositionAnchor = .init(time:100,crop:.init(x:0.2,y:0.1,width:0.2,height:0.6320987654320988))
        let worker=Task.detached {
            CropPlan.make(samples:samples,source:.init(width:1920,height:1080),settings:settings)
        }
        worker.cancel()
        let cancelled=await worker.value
        XCTAssertTrue(cancelled.isEmpty,"A cancelled solve must not publish a partially optimized camera path")
        let rendered=await Task.detached {
            withUnsafeCurrentTask {$0?.cancel()}
            return CropPlan.renderFrames([.init(time:0,rect:.init(x:0,y:0,width:100,height:100))],frameRate:30)
        }.value
        XCTAssertTrue(rendered.isEmpty)
    }
}
