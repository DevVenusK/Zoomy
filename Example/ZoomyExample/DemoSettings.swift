import CoreGraphics
import Foundation
import Zoomy

/// Shared, persisted demo settings for the example app. Currently exposes the zoom spring's
/// **speed** (`response`, the perceived duration) and **bounciness** (`dampingRatio`), which the
/// grid screens read when building a `ZoomTransition`. Backed by `UserDefaults` so a choice made in
/// the Settings tab survives relaunches.
final class DemoSettings {

    static let shared = DemoSettings()

    /// Defaults mirror `ZoomTransition.Configuration.default.spring`.
    static let defaultResponse: Double = 0.44
    static let defaultDampingRatio: Double = 0.85

    /// Slider bounds surfaced by the Settings screen.
    static let responseRange: ClosedRange<Double> = 0.1...2.0
    static let dampingRange: ClosedRange<Double> = 0.5...1.0

    private let defaults: UserDefaults
    private let responseKey = "zoomy.demo.springResponse"
    private let dampingKey = "zoomy.demo.springDampingRatio"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Perceived zoom duration in seconds. Lower = faster.
    var springResponse: Double {
        get { defaults.object(forKey: responseKey) as? Double ?? Self.defaultResponse }
        set { defaults.set(newValue, forKey: responseKey) }
    }

    /// Spring damping ratio. Lower = bouncier; 1.0 = no overshoot.
    var springDampingRatio: Double {
        get { defaults.object(forKey: dampingKey) as? Double ?? Self.defaultDampingRatio }
        set { defaults.set(newValue, forKey: dampingKey) }
    }

    func resetToDefaults() {
        springResponse = Self.defaultResponse
        springDampingRatio = Self.defaultDampingRatio
    }

    /// A fresh `ZoomTransition.Configuration` reflecting the current spring settings.
    func makeConfiguration() -> ZoomTransition.Configuration {
        var configuration = ZoomTransition.Configuration()
        configuration.spring = ZoomTransition.Spring(
            response: springResponse,
            dampingRatio: CGFloat(springDampingRatio)
        )
        return configuration
    }
}
