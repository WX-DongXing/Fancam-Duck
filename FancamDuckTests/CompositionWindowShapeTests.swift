import XCTest
import SwiftUI
@testable import FancamDuck

final class CompositionWindowShapeTests:XCTestCase {
    func testHoleAndOutlineShareInterpolatedWindowDuringAspectChange() {
        let start=CGRect(x:100,y:20,width:180,height:320)
        let end=CGRect(x:30,y:80,width:320,height:240)
        let initial=CompositionWindowShape(window:start)
        let target=CompositionWindowShape(window:end)
        var delta=target.animatableData-initial.animatableData
        delta.scale(by:0.5)
        var outline=initial
        outline.animatableData=initial.animatableData+delta
        XCTAssertEqual(outline.window,CGRect(x:65,y:50,width:250,height:280))
        var mask=CompositionWindowShape(window:start,inverted:true)
        mask.animatableData=outline.animatableData
        let canvas=CGRect(x:0,y:0,width:400,height:400)
        let path=mask.path(in:canvas)
        XCTAssertFalse(path.contains(CGPoint(x:70,y:100),eoFill:true),"The clear hole must follow the intermediate edge, not the final edge")
        XCTAssertTrue(path.contains(CGPoint(x:40,y:100),eoFill:true))
        XCTAssertEqual(outline.path(in:canvas).boundingRect,mask.window)
        mask.animatableData=target.animatableData
        XCTAssertEqual(mask.window,end)
    }
}
