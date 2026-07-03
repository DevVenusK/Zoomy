import UIKit

/// Fallback strategy (`docs/TECH_SPEC.md` §5.9 / §8): a plain cross-dissolve used when the
/// source view can't be resolved (and, in M7, for Reduce Motion / VoiceOver). No portal, no
/// source hide, no placard — just an alpha fade, plus a center 85% shrink on dismiss.
///
/// It produces no geometry animator: the completion barrier runs on the single transition
/// animator (`pendingAnimatorCount == 1`), which is why the driver tolerates an empty geometry
/// array.
@MainActor
final class CrossDissolveAnimator: ZoomTransitionAnimating {

    private static let dismissShrink = CGAffineTransform(scaleX: 0.85, y: 0.85)

    func prepare(using context: ZoomAnimationContext) {
        let container = context.containerView
        let zoomedView = context.zoomedView

        context.restorationToken.recordAlpha(of: zoomedView)

        switch context.phase {
        case .appearing:
            container.addSubview(zoomedView)
            zoomedView.frame = context.finalFrame
            zoomedView.alpha = 0
            context.dimmingView?.alpha = 0
        case .disappearing:
            // The departing view is already in the container; ensure a clean starting alpha.
            zoomedView.alpha = 1
            context.dimmingView?.alpha = 1
        }

        container.layoutIfNeeded()
    }

    func makeAnimators(
        using context: ZoomAnimationContext
    ) -> (transition: UIViewPropertyAnimator, geometry: [UIViewPropertyAnimator]) {
        let spring = context.configuration.spring
        let timing = SpringConverter.timingParameters(
            response: spring.response,
            dampingRatio: spring.dampingRatio
        )
        let animator = UIViewPropertyAnimator(duration: spring.response, timingParameters: timing)
        let zoomedView = context.zoomedView

        switch context.phase {
        case .appearing:
            animator.addAnimations {
                zoomedView.alpha = 1
                context.dimmingView?.alpha = 1
            }
        case .disappearing:
            animator.addAnimations {
                zoomedView.alpha = 0
                zoomedView.transform = Self.dismissShrink
                context.dimmingView?.alpha = 0
            }
        }

        return (animator, [])
    }

    func finish(using context: ZoomAnimationContext, completed: Bool) {
        switch (context.phase, completed) {
        case (.appearing, true):
            // Live view stays in the container; alpha is restored by the token.
            context.zoomedView.transform = .identity
        case (.disappearing, true):
            // UIKit removes the departing view; nothing to reparent.
            break
        default:
            // Non-interactive fallback has no cancel path (M6).
            break
        }
    }
}
