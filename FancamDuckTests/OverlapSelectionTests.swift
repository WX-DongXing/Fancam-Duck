import XCTest
@testable import FancamDuck

final class OverlapSelectionTests:XCTestCase {
    private func person(_ id:Int,_ x:Double,_ y:Double,_ width:Double,_ height:Double)->OverlapPerson {
        .init(id:id,number:id,body:.init(x:x,y:y,width:width,height:height))
    }
    func testExactlyHalfAndSeparatedCandidatesDoNotTrigger() {
        XCTAssertTrue(OverlapSelection.candidates([person(0,0,0,0.4,0.8),person(1,0.2,0,0.4,0.8)]).isEmpty)
        XCTAssertTrue(OverlapSelection.candidates([person(0,0,0,0.2,0.8),person(1,0.6,0,0.2,0.8)]).isEmpty)
    }
    func testOnlyOverlappingPeopleAreOfferedAndContainmentUsesSmallerArea() {
        let result=OverlapSelection.candidates([person(0,0.1,0.1,0.6,0.8),person(1,0.3,0.2,0.1,0.3),person(2,0.8,0.1,0.1,0.8)])
        XCTAssertEqual(result.map(\.id),[0,1])
    }
    func testInvalidOrSingleCandidatesNeverTrigger() {
        XCTAssertTrue(OverlapSelection.candidates([person(0,0,0,0.2,0.8)]).isEmpty)
        XCTAssertTrue(OverlapSelection.candidates([person(0,0,0,0,0.8),person(1,0,0,0.2,0.8)]).isEmpty)
    }
}
