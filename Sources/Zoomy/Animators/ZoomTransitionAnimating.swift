import UIKit
import ZoomyCore

/// Strategy interface `TransitionDriver` runs a transition through. `ZoomAnimator` is the real
/// zoom choreography; `CrossDissolveAnimator` is the fallback (unresolvable source, and later
/// Reduce Motion / VoiceOver — M7). The driver owns the procedure (state machine, completion
/// barrier, cleanup, `completeTransition`); the strategy owns view scaffolding and the animated
/// property targets. See `docs/TECH_SPEC.md` §5.9.
@MainActor
protocol ZoomTransitionAnimating: AnyObject {
    /// Places views in the container and sets their initial states. Called before any animator
    /// is created.
    func prepare(using context: ZoomAnimationContext)

    /// Returns `(transitionAnimator, geometryAnimators)`. Property ownership must follow the
    /// split in `docs/TECH_SPEC.md` §6.2: the transition animator only carries scrub/reverse
    /// safe properties (dimming alpha, presenter push-back, placard keyframes, corner morph);
    /// geometry animators carry portal frame and live-view transform. Both use the same spring.
    /// The two are separate even for non-interactive runs so M6's grab can kill and rebuild the
    /// geometry animators alone (TECH_SPEC §14-2).
    func makeAnimators(
        using context: ZoomAnimationContext
    ) -> (transition: UIViewPropertyAnimator, geometry: [UIViewPropertyAnimator])

    /// Called once after the completion barrier fires (or the abandoned-transition backstop),
    /// immediately before the driver restores the `RestorationToken` — removes the strategy's
    /// own scaffolding (portal, reparenting) and puts the live view back where it belongs.
    func finish(using context: ZoomAnimationContext, completed: Bool)
}

/// Everything a strategy needs to stage and animate one transition, resolved by
/// `TransitionDriver` from the `UIViewControllerContextTransitioning` + `ZoomTransition` state.
@MainActor
final class ZoomAnimationContext {
    let containerView: UIView
    let phase: ZoomTransition.Phase
    /// The live destination root view (or, during dismissal, the departing root view).
    let zoomedView: UIView
    let zoomedViewController: UIViewController
    /// A push's `toView`, or a modal `.fullScreen` dismissal's re-inserted presenter view
    /// (`transitionContext.view(forKey: .to)`); `nil` for `.custom`/`.overFullScreen`, where
    /// the presenter's view survives outside the container.
    let backgroundView: UIView?
    /// `nil` means the source couldn't be resolved — the fallback path is running.
    let resolvedSource: ResolvedSource?
    /// Only non-nil when `resolvedSource` is.
    let geometry: ZoomGeometry?
    let configuration: ZoomTransition.Configuration
    let restorationToken: RestorationToken
    /// Owned by the presentation controller (modal); `nil` when there is none.
    let dimmingView: UIView?
    /// The push-back transform target (modal `.custom`'s surviving presenter view).
    let presenterView: UIView?
    /// Created and injected by the driver; the strategy decides whether to install it.
    let portal: PortalView
    /// The zoomed view's resting frame in `containerView` coordinates — appearing: its final
    /// frame; disappearing: the frame it currently rests at.
    let finalFrame: CGRect

    init(
        containerView: UIView,
        phase: ZoomTransition.Phase,
        zoomedView: UIView,
        zoomedViewController: UIViewController,
        backgroundView: UIView?,
        resolvedSource: ResolvedSource?,
        geometry: ZoomGeometry?,
        configuration: ZoomTransition.Configuration,
        restorationToken: RestorationToken,
        dimmingView: UIView?,
        presenterView: UIView?,
        portal: PortalView,
        finalFrame: CGRect
    ) {
        self.containerView = containerView
        self.phase = phase
        self.zoomedView = zoomedView
        self.zoomedViewController = zoomedViewController
        self.backgroundView = backgroundView
        self.resolvedSource = resolvedSource
        self.geometry = geometry
        self.configuration = configuration
        self.restorationToken = restorationToken
        self.dimmingView = dimmingView
        self.presenterView = presenterView
        self.portal = portal
        self.finalFrame = finalFrame
    }
}
