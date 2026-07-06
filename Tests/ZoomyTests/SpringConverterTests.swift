import XCTest
import UIKit
@testable import Zoomy

final class SpringConverterTests: XCTestCase {

    // Note: UISpringTimingParameters exposes no public getter for dampingRatio/mass/stiffness/
    // damping (confirmed against the SDK — only `initialVelocity` is inspectable), so these tests
    // are limited to what's actually observable, per the brief's own "UIKit 래퍼 (테스트는 수치만)"
    // note. The underlying stiffness/damping math is fully covered by SpringMathTests above.

    func test_timingParameters_defaultInitialVelocityIsZero() {
        let parameters = SpringConverter.timingParameters(response: 0.44, dampingRatio: 0.85)
        XCTAssertEqual(parameters.initialVelocity, .zero)
    }

    func test_timingParameters_passesThroughInitialVelocity() {
        let velocity = CGVector(dx: 1.5, dy: -2.5)
        let parameters = SpringConverter.timingParameters(
            response: 0.44,
            dampingRatio: 0.85,
            initialVelocity: velocity
        )
        XCTAssertEqual(parameters.initialVelocity, velocity)
    }

    // MARK: - normalizedVelocity

    func test_normalizedVelocity_dividesByRemainingDistancePerAxis() {
        let result = SpringConverter.normalizedVelocity(
            CGPoint(x: 100, y: 50),
            remainingDistance: CGPoint(x: 200, y: 100)
        )
        XCTAssertEqual(result.dx, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.dy, 0.5, accuracy: 0.0001)
    }

    func test_normalizedVelocity_guardsZeroDistanceWithMinimumDenominatorOfOne() {
        let result = SpringConverter.normalizedVelocity(
            CGPoint(x: 100, y: 50),
            remainingDistance: .zero
        )
        XCTAssertEqual(result.dx, 100, accuracy: 0.0001)
        XCTAssertEqual(result.dy, 50, accuracy: 0.0001)
    }

    func test_normalizedVelocity_guardsSubOneDistancePerAxisIndependently() {
        // x has sub-1 remaining distance (guarded to 1), y does not.
        let result = SpringConverter.normalizedVelocity(
            CGPoint(x: 10, y: 10),
            remainingDistance: CGPoint(x: 0.5, y: 5)
        )
        XCTAssertEqual(result.dx, 10, accuracy: 0.0001) // 10 / max(0.5, 1) = 10 / 1
        XCTAssertEqual(result.dy, 2, accuracy: 0.0001)  // 10 / max(5, 1) = 10 / 5
    }
}
