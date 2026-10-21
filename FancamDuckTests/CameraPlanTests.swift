import XCTest
@testable import FancamDuck

final class CameraPlanTests:XCTestCase {
    func testEdgeHandlesResizeOnlyTheirAxisAndPreserveOppositeEdge() {
        let box=NormalizedRect(x:0.2,y:0.2,width:0.4,height:0.5)
        let top=ManualBoxGeometry.resize(box,edge:.top,dx:0.3,dy:0.1)
        XCTAssertEqual(top.x,box.x);XCTAssertEqual(top.width,box.width,accuracy:0.001)
        XCTAssertEqual(top.y+top.height,0.7,accuracy:0.001)
        let bottom=ManualBoxGeometry.resize(box,edge:.bottom,dx:0.3,dy:0.1)
        XCTAssertEqual(bottom.y,box.y);XCTAssertEqual(bottom.height,0.6,accuracy:0.001)
        let left=ManualBoxGeometry.resize(box,edge:.left,dx:0.1,dy:0.3)
        XCTAssertEqual(left.y,box.y);XCTAssertEqual(left.height,box.height,accuracy:0.001)
        XCTAssertEqual(left.x+left.width,0.6,accuracy:0.001)
        let right=ManualBoxGeometry.resize(box,edge:.right,dx:0.1,dy:0.3)
        XCTAssertEqual(right.x,box.x);XCTAssertEqual(right.width,0.5,accuracy:0.001)
        let clamped=ManualBoxGeometry.resize(box,edge:.right,dx:-2,dy:0)
        XCTAssertEqual(clamped.width,0.06,accuracy:0.001)
    }

    func testFrameMultipleRoundoffDoesNotCreateZeroLengthTail() {
        let times=[0.0,0.3,0.6000000000000001]
        let path=times.map {CropPlan.Frame(time:$0,rect:.init(x:400+$0*10,y:30,width:300,height:533))}
        let rendered=CropPlan.renderFrames(path,frameRate:25)
        XCTAssertEqual(rendered.count,16)
        XCTAssertEqual(rendered.last?.time,times.last)
        XCTAssertTrue(zip(rendered,rendered.dropFirst()).allSatisfy {$1.time-$0.time>0.039999})
    }
    func testRenderInterpolationDoesNotOvershootAtTurnsOrIrregularTail() {
        let xs=[400.0,430,450,450,430,420],times=[0.0,0.1,0.2,0.3,0.4,0.42]
        let path=zip(times,xs).map {CropPlan.Frame(time:$0.0,rect:.init(x:$0.1-150,y:30,width:300,height:533.333))}
        let rendered=CropPlan.renderFrames(path,frameRate:25)
        XCTAssertEqual(rendered.first?.time,0);XCTAssertEqual(rendered.last?.time,0.42)
        XCTAssertTrue(zip(rendered,rendered.dropFirst()).allSatisfy {$0.time<$1.time})
        for frame in rendered {
            let index=min(path.count-2,max(0,(path.lastIndex {$0.time<=frame.time} ?? 0)))
            XCTAssertGreaterThanOrEqual(frame.rect.midX,min(xs[index],xs[index+1])-0.00001)
            XCTAssertLessThanOrEqual(frame.rect.midX,max(xs[index],xs[index+1])+0.00001)
            XCTAssertEqual(frame.rect.height,533.333,accuracy:0.00001)
        }
    }
    func testFullBodyBoundsSurviveSuddenDirectionChangeAndPartialStep() {
        let samples=(0...60).map { i -> TargetSample in
            let t=min(5.93,Double(i)*0.1),x=0.45+0.2*sin(t*0.8)
            return .init(time:t,body:.init(x:x,y:0.2,width:0.12,height:0.6))
        }
        var legacy=EditSettings();legacy.subjectComposition=nil
        let plan=CropPlan.make(samples:samples,source:.init(width:1920,height:1080),settings:legacy)
        for frame in plan {
            let sample=samples.first {abs($0.time-frame.time)<0.0001}!
            XCTAssertLessThanOrEqual(frame.rect.minX,sample.body.x*1920+0.001)
            XCTAssertGreaterThanOrEqual(frame.rect.maxX,(sample.body.x+sample.body.width)*1920-0.001)
            XCTAssertGreaterThanOrEqual(frame.rect.minX,-0.001)
            XCTAssertLessThanOrEqual(frame.rect.maxX,1920.001)
        }
    }
    func testCameraDoesNotBreatheOrBounceWithDancePose() {
        let samples=(0..<120).map { i -> TargetSample in
            let t=Double(i)*0.1
            let x=0.3+0.001*Double(i)+0.018*sin(Double(i)*1.8)
            return .init(time:t,body:.init(x:x,y:0.3+0.025*sin(Double(i)*1.3),width:0.11+0.025*abs(sin(Double(i))),height:0.38+0.045*sin(Double(i)*0.9)))
        }
        var legacy=EditSettings();legacy.subjectComposition=nil
        let plan=CropPlan.make(samples:samples,source:.init(width:1920,height:1080),settings:legacy)
        XCTAssertEqual(plan.count,samples.count)
        XCTAssertLessThan(plan.map(\.rect.height).max()!-plan.map(\.rect.height).min()!,0.001)
        XCTAssertLessThan(plan.map(\.rect.midY).max()!-plan.map(\.rect.midY).min()!,0.001)
        func acceleration(_ x:[Double]) -> Double { (2..<x.count).map { abs(x[$0]-2*x[$0-1]+x[$0-2]) }.max()! }
        let cameraX:[Double]=plan.map { Double($0.rect.midX) }
        let detectionX:[Double]=samples.map { Double($0.body.center.x)*1920.0 }
        XCTAssertLessThan(acceleration(cameraX),acceleration(detectionX)*0.2)
        XCTAssertTrue(plan.allSatisfy { $0.rect.minX >= -0.001 && $0.rect.maxX <= 1920.001 && $0.rect.minY >= -0.001 && $0.rect.maxY <= 1080.001 })
    }
    func testManualHandlesKeepOppositeCornerAndBounds() {
        let box=NormalizedRect(x:0.2,y:0.2,width:0.3,height:0.5)
        let resized=ManualBoxGeometry.resize(box,corner:.topLeft,dx:-0.5,dy:-0.5)
        XCTAssertEqual(resized.x,0);XCTAssertEqual(resized.y,0)
        XCTAssertEqual(resized.x+resized.width,0.5,accuracy:0.0001)
        XCTAssertEqual(resized.y+resized.height,0.7,accuracy:0.0001)
        let tiny=ManualBoxGeometry.resize(box,corner:.bottomRight,dx:-1,dy:-1)
        XCTAssertEqual(tiny.width,0.06,accuracy:0.0001);XCTAssertEqual(tiny.height,0.1,accuracy:0.0001)
        let moved=ManualBoxGeometry.move(box,dx:2,dy:2)
        XCTAssertEqual(moved.x+moved.width,1,accuracy:0.0001);XCTAssertEqual(moved.y+moved.height,1,accuracy:0.0001)
    }
    func testExtendedLegOverlapIsDistinctFromActualIdentityCrossing() {
        func person(_ id:Int,_ hip:Double) -> PersonObservation {
            var p=PersonObservation(id:id,body:.init(x:0.35,y:0.2,width:0.3,height:0.6),confidence:0.9,embedding:[1,0])
            p.keypoints=Array(repeating:.init(x:hip,y:0.5,confidence:0.9),count:17)
            return p
        }
        let target=person(1,0.45)
        XCTAssertFalse(PersonIdentityGate.isAmbiguous(target:target,others:[person(2,0.6)],previousFocus:0.45,gallery:[[1,0]]))
        var crossing=person(2,0.46)
        crossing.keypoints[5] = .init(x:0.6,y:0.3,confidence:0.9)
        crossing.keypoints[6] = .init(x:0.3,y:0.3,confidence:0.9)
        crossing.keypoints[7] = .init(x:0.2,y:0.4,confidence:0.9)
        crossing.keypoints[8] = .init(x:0.7,y:0.4,confidence:0.9)
        XCTAssertTrue(PersonIdentityGate.isAmbiguous(target:target,others:[crossing],previousFocus:0.45,gallery:[[1,0]]))
        XCTAssertFalse(PersonIdentityGate.isAmbiguous(target:target,others:[person(3,0.451)],previousFocus:0.45,gallery:[[1,0]]))
    }

}
