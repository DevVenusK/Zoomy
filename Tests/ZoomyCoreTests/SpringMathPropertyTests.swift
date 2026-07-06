import XCTest
import ZoomyCore

/// Property-based tests for `SpringMath.constants` closed-form spring math.
final class SpringMathPropertyTests: XCTestCase {

    // MARK: - positivity

    func test_property_constants_arePositiveForPositiveInputs() {
        checkProperty("response > 0, ratio > 0 ⇒ stiffness > 0, damping > 0", iterations: 1_000) { rng -> (Double, Double) in
            (randomDouble(in: 0.01...5, using: &rng), randomDouble(in: 0.01...5, using: &rng))
        } holds: { input in
            let (response, ratio) = input
            let constants = SpringMath.constants(response: response, dampingRatio: ratio)
            return constants.stiffness > 0 && constants.damping > 0
        }
    }

    // MARK: - closed form

    func test_property_constants_matchClosedForm() {
        checkProperty("stiffness == (2π/response)², damping == 2·ratio·(2π/response)", iterations: 1_000) { rng -> (Double, Double) in
            (randomDouble(in: 0.01...5, using: &rng), randomDouble(in: 0.01...5, using: &rng))
        } holds: { input in
            let (response, ratio) = input
            let constants = SpringMath.constants(response: response, dampingRatio: ratio)
            let angular = 2 * Double.pi / response
            let expectedStiffness = angular * angular
            let expectedDamping = 2 * ratio * angular
            return approxEqual(constants.stiffness, expectedStiffness)
                && approxEqual(constants.damping, expectedDamping)
        }
    }
}
