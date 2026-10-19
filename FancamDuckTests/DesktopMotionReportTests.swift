import XCTest
@testable import FancamDuck

final class DesktopMotionReportTests:XCTestCase {
    func testRecordSteadyCameraMetricsForCompletedDesktopTrajectory() throws {
        guard ProcessInfo.processInfo.environment["FANCAM_DUCK_DESKTOP_METRICS"] == "1" else { throw XCTSkip("Local completed desktop trajectory opt-in") }
        let temporary=FileManager.default.temporaryDirectory
        let samples=try JSONDecoder().decode([TargetSample].self,from:Data(contentsOf:temporary.appendingPathComponent("FancamDuck-last-trajectory.json")))
        XCTAssertGreaterThan(samples.map(\.time).max()!,37)
        let settings=EditSettings(),source=CGSize(width:3840,height:2160)
        let plan=CropPlan.make(samples:samples,source:source,settings:settings)
        let heights=plan.map { Double($0.rect.height) },ys=plan.map { Double($0.rect.midY) },xs=plan.map { Double($0.rect.midX) }
        XCTAssertLessThan(heights.max()!-heights.min()!,0.001)
        XCTAssertLessThan(ys.max()!-ys.min()!,0.001)
        let maxVelocity=(1..<plan.count).map { abs(xs[$0]-xs[$0-1])/max(0.001,plan[$0].time-plan[$0-1].time) }.max()!
        let maxAcceleration=(2..<plan.count).map { i -> Double in
            let dt1=max(0.001,plan[i-1].time-plan[i-2].time),dt2=max(0.001,plan[i].time-plan[i-1].time)
            return abs(2*((xs[i]-xs[i-1])/dt2-(xs[i-1]-xs[i-2])/dt1)/(dt1+dt2))
        }.max()!
        print("STEADY_CAMERA samples=\(plan.count) height=\(heights[0]) zoomVariation=\(heights.max()!-heights.min()!) verticalVariation=\(ys.max()!-ys.min()!) maxHorizontalVelocityPixelsPerSecond=\(maxVelocity) maxHorizontalAccelerationPixelsPerSecondSquared=\(maxAcceleration)")
        let data=try JSONEncoder().encode(plan)
        let url=temporary.appendingPathComponent("FancamDuck-steady-camera-report.json");try data.write(to:url)
        let attachment=XCTAttachment(contentsOfFile:url);attachment.name="Steady camera trajectory";attachment.lifetime = .keepAlways;add(attachment)
    }
}
