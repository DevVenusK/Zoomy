import CoreGraphics

/// Pure spring-constant math — no UIKit dependency.
public enum SpringMath {
    /// mass 1 기준. stiffness = (2π/response)², damping = 2·dampingRatio·(2π/response)
    public static func constants(response: Double, dampingRatio: Double) -> (stiffness: Double, damping: Double) {
        let angularFrequency = 2 * Double.pi / response
        let stiffness = angularFrequency * angularFrequency
        let damping = 2 * dampingRatio * angularFrequency
        return (stiffness, damping)
    }
}
