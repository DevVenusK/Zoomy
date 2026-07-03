import UIKit

/// The `UIViewControllerTransitioningDelegate` a `ZoomTransition` installs on its attached view
/// controller (see `UIViewController.zoomTransition`'s setter).
///
/// M3a stub: every vend point returns `nil`, so UIKit falls back to its system-default
/// presentation/dismissal animation. Real zoom choreography (`TransitionDriver`,
/// `ZoomInteractionDriver`, `ZoomPresentationController`) lands in M3b — this keeps the library
/// in a safe, compiling, "does nothing surprising" state in the interim: assigning
/// `zoomTransition` and presenting is functionally a no-op beyond the `.custom` presentation
/// style plumbing the setter installs.
final class ModalTransitioningAdapter: NSObject, UIViewControllerTransitioningDelegate {
    unowned let transition: ZoomTransition

    init(transition: ZoomTransition) {
        self.transition = transition
    }

    // TODO(M3b): gate on state/Reduce Motion/VoiceOver and vend TransitionDriver or a
    // CrossDissolve fallback driver instead of `nil` (see `docs/TECH_SPEC.md` §5.8).
    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        nil
    }

    // TODO(M3b): vend TransitionDriver instead of `nil`.
    func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        nil
    }

    // TODO(M3b): vend a ZoomInteractionDriver when `configuration.interactiveDismissal == .pan`.
    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        nil
    }

    // TODO(M3b): vend ZoomPresentationController when the presented style is `.custom`.
    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        nil
    }
}
