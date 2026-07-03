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
        return TransitionDriver(transition: transition, phase: .appearing, operation: .present)
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard transition.stateMachine.state == .idle else {
            logReentrantRejection(direction: "dismiss")
            return nil
        }
        return TransitionDriver(transition: transition, phase: .disappearing, operation: .dismiss)
    }

    // TODO(M6): vend a ZoomInteractionDriver when `configuration.interactiveDismissal == .pan`.
    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        nil
    }

    // TODO(M6): vend the driver (wantsInteractiveStart = false) so a grab mid-present is legal.
    func interactionControllerForPresentation(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        nil
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
