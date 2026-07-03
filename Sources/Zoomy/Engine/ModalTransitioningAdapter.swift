import UIKit
import os.log

/// The `UIViewControllerTransitioningDelegate` a `ZoomTransition` installs on its attached view
/// controller (see `UIViewController.zoomTransition`'s setter). Vends a `TransitionDriver` for
/// present/dismiss and a `ZoomPresentationController` for `.custom` presentations, gating every
/// animation controller on the state machine being idle (the reentrancy guard, §8).
///
/// Interactive dismissal (`interactionControllerFor…`) and Reduce Motion / VoiceOver gating are
/// M6/M7 — those vend points still return `nil`.
final class ModalTransitioningAdapter: NSObject, UIViewControllerTransitioningDelegate {
    unowned let transition: ZoomTransition

    init(transition: ZoomTransition) {
        self.transition = transition
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard transition.stateMachine.state == .idle else {
            logReentrantRejection(direction: "present")
            return nil
        }
        // Reduce Motion / VoiceOver (§9): the same driver runs a cross-dissolve instead of the zoom.
        return TransitionDriver(
            transition: transition,
            phase: .appearing,
            operation: .present,
            forcedFallbackReason: transition.accessibilityFallbackReason
        )
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard transition.stateMachine.state == .idle else {
            logReentrantRejection(direction: "dismiss")
            return nil
        }
        return TransitionDriver(
            transition: transition,
            phase: .disappearing,
            operation: .dismiss,
            forcedFallbackReason: transition.accessibilityFallbackReason
        )
    }

    /// Interactive dismissal (§6): vend the pan driver **only when a gesture is actually driving
    /// the dismiss** (`isGestureActive`). A programmatic `dismiss(animated:)` (close button) leaves
    /// the recognizer idle, so this returns `nil` and 3b's non-interactive `TransitionDriver` runs
    /// unchanged (§5).
    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        guard transition.configuration.interactiveDismissal == .pan,
              !transition.suppressesInteractionForAccessibility,
              let driver = transition.interactionDriver, driver.isGestureActive else {
            return nil
        }
        driver.wantsInteractiveStart = true
        driver.animationDriver = animator as? TransitionDriver
        return driver
    }

    /// Vend the driver (started non-interactively) so a grab during the present zoom is legal (§6).
    /// The present runs animated via `startInteractiveTransition`'s present-guard (which forwards to
    /// the animator); the driver only takes over if a pan later grabs it. A grab mid-present is only
    /// reachable once the recognizer is installed (`presentationTransitionDidEnd`), i.e. after the
    /// present completes — full mid-present takeover is deferred (TODO(M7)).
    func interactionControllerForPresentation(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        guard transition.configuration.interactiveDismissal == .pan else { return nil }
        let driver = transition.makeInteractionDriver(operation: .dismiss)
        driver.wantsInteractiveStart = false
        driver.animationDriver = animator as? TransitionDriver
        return driver
    }

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        guard presented.modalPresentationStyle == .custom else { return nil }
        return ZoomPresentationController(
            presentedViewController: presented,
            presenting: presenting,
            transition: transition
        )
    }

    /// Reentrant rejection returns `nil` (system default) *without* reporting a `Result` — a
    /// zoom/fallback never actually ran, so a `didEnd` here would be mistaken for the end of a
    /// real transition (§8). DEBUG diagnostics only.
    private func logReentrantRejection(direction: String) {
        #if DEBUG
        os_log(
            "ZoomTransition %{public}@ vend rejected: state machine not idle (reentrant)",
            log: .zoomy,
            type: .debug,
            direction
        )
        #endif
    }
}
