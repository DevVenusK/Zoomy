import XCTest
import ZoomyCore

final class SpringMathTests: XCTestCase {

    func test_constants_response044_dampingRatio085() {
        let constants = SpringMath.constants(response: 0.44, dampingRatio: 0.85)
        XCTAssertEqual(constants.stiffness, 203.9, accuracy: 0.1)
        XCTAssertEqual(constants.damping, 24.27, accuracy: 0.1)
    }
}
