import CoreGraphics

/// Pure spring-constant math — no UIKit dependency.
enum SpringMath {
    /// mass 1 기준. stiffness = (2π/response)², damping = 2·dampingRatio·(2π/response)
    static func constants(response: Double, dampingRatio: Double) -> (stiffness: Double, damping: Double) {
        let angularFrequency = 2 * Double.pi / response
        let stiffness = angularFrequency * angularFrequency
        let damping = 2 * dampingRatio * angularFrequency
        return (stiffness, damping)
    }
}

import UIKit

/// UIKit wrapper around `SpringMath` — the sole place in the Engine/Support layer allowed to
/// import UIKit.
enum SpringConverter {
    static func timingParameters(
        response: Double,
        dampingRatio: Double,
        initialVelocity: CGVector = .zero
    ) -> UISpringTimingParameters {
        let constants = SpringMath.constants(response: response, dampingRatio: dampingRatio)
        return UISpringTimingParameters(
            mass: 1,
            stiffness: CGFloat(constants.stiffness),
            damping: CGFloat(constants.damping),
            initialVelocity: initialVelocity
        )
    }

    /// initialVelocity 정규화 헬퍼: 축별 v/max(남은거리,1)
    static func normalizedVelocity(_ velocity: CGPoint, remainingDistance: CGPoint) -> CGVector {
        CGVector(
            dx: velocity.x / max(remainingDistance.x, 1),
            dy: velocity.y / max(remainingDistance.y, 1)
        )
    }
}
