import UIKit

/// An injectable seam over the handful of `UIAccessibility` flags Zoomy gates on (`docs/TECH_SPEC.md`
/// §9). Production reads the real `UIAccessibility` singletons; tests inject a stub, because those
/// flags cannot be toggled from a unit test. Internal only — never part of the public surface.
@MainActor
protocol AccessibilityEnvironment {
    /// `UIAccessibility.isReduceMotionEnabled`.
    var isReduceMotionEnabled: Bool { get }
    /// `UIAccessibility.prefersCrossFadeTransitions` (iOS 14+, always available at our iOS 15 min).
    var prefersCrossFadeTransitions: Bool { get }
    /// `UIAccessibility.isVoiceOverRunning`.
    var isVoiceOverRunning: Bool { get }
}

/// The production `AccessibilityEnvironment`: a thin pass-through to the live `UIAccessibility` flags.
struct SystemAccessibilityEnvironment: AccessibilityEnvironment {
    var isReduceMotionEnabled: Bool { UIAccessibility.isReduceMotionEnabled }
    var prefersCrossFadeTransitions: Bool { UIAccessibility.prefersCrossFadeTransitions }
    var isVoiceOverRunning: Bool { UIAccessibility.isVoiceOverRunning }
}

extension ZoomTransition {
    /// The fallback reason a zoom must degrade to a cross-dissolve for on accessibility grounds, or
    /// `nil` to run the real zoom (§9):
    /// - VoiceOver running → always cross-dissolve (independent of `respectsReduceMotion`).
    /// - Reduce Motion / Prefer Cross-Fade → cross-dissolve **only when** `respectsReduceMotion`.
    ///
    /// Both surface as `.reduceMotion` (the enum case documents itself as covering VoiceOver too).
    /// Evaluated at animator-vend time, so a mid-run toggle never changes an in-flight transition.
    var accessibilityFallbackReason: FallbackReason? {
        if accessibilityEnvironment.isVoiceOverRunning { return .reduceMotion }
        if configuration.respectsReduceMotion,
           accessibilityEnvironment.isReduceMotionEnabled
            || accessibilityEnvironment.prefersCrossFadeTransitions {
            return .reduceMotion
        }
        return nil
    }

    /// Whether interactive dismissal must be suppressed (VoiceOver): the pan/edge gestures are not
    /// installed (or are disabled if already installed) and `gestureRecognizerShouldBegin` refuses,
    /// so a dismissal always runs as the non-interactive cross-dissolve.
    var suppressesInteractionForAccessibility: Bool {
        accessibilityEnvironment.isVoiceOverRunning
    }
}
