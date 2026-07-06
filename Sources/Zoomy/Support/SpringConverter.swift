import UIKit
import ZoomyCore

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
