import XCTest
import SwiftUI
@testable import FancamDuck

@MainActor final class NativeSegmentedControlTests:XCTestCase {
    func testValueChangeDoesNotRollBackWhileBindingAwaitsNextRender() {
        var pending:Int?
        // A SwiftUI render can still expose the previous value during valueChanged.
        let view=NativeSegmentedControl(title:"设置",options:[0,1,2],selection:Binding(get:{0},set:{pending=$0}),label:{String($0)})
        let coordinator=view.makeCoordinator()
        let control=UISegmentedControl(items:["0","1","2"])
        control.selectedSegmentIndex=1
        coordinator.changed(control)
        XCTAssertEqual(pending,1)
        XCTAssertEqual(control.selectedSegmentIndex,1,"Keep native feedback until the next model render reconciles selection")
    }
    func testUnrelatedRendersDoNotRewriteNativeSelectionOrTitles() {
        let view=NativeSegmentedControl(title:"设置",options:[0,1,2],selection:.constant(1),label:{String($0)})
        let coordinator=view.makeCoordinator(),control=RecordingControl()
        view.updateControl(control,coordinator:coordinator)
        control.selectionWrites=0;control.titleWrites=0
        for _ in 0..<20 {view.updateControl(control,coordinator:coordinator)}
        XCTAssertEqual(control.selectionWrites,0)
        XCTAssertEqual(control.titleWrites,0)
        XCTAssertEqual(control.selectedSegmentIndex,1)
    }

    func testNextRenderReconcilesRejectedSelectionAndChangedOptions() {
        let view=NativeSegmentedControl(title:"设置",options:[0,1,2],selection:.constant(0),label:{String($0)})
        let coordinator=view.makeCoordinator(),control=UISegmentedControl()
        view.updateControl(control,coordinator:coordinator)
        control.selectedSegmentIndex=1;coordinator.changed(control)
        view.updateControl(control,coordinator:coordinator)
        XCTAssertEqual(control.selectedSegmentIndex,0)
        let next=NativeSegmentedControl(title:"设置",options:[2,0],selection:.constant(0),label:{String($0)})
        next.updateControl(control,coordinator:coordinator)
        XCTAssertEqual(control.numberOfSegments,2)
        XCTAssertEqual(control.selectedSegmentIndex,1)
        XCTAssertEqual(control.titleForSegment(at:0),"2")
    }

    private final class RecordingControl:UISegmentedControl {
        var selectionWrites=0
        var titleWrites=0
        override var selectedSegmentIndex:Int {didSet {selectionWrites+=1}}
        override func setTitleTextAttributes(_ attributes:[NSAttributedString.Key:Any]?,for state:UIControl.State) {
            titleWrites+=1
            super.setTitleTextAttributes(attributes,for:state)
        }
    }

}
