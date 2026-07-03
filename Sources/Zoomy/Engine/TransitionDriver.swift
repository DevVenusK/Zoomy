import UIKit
import os.log

/// One-shot state for a single in-flight transition. Held by `ZoomTransition.activeTransition`
/// while (and only while) a transition is running; dropped to `nil` by the driver's single-exit
/// `cleanup`, which is also the point the animators and `UIViewControllerContextTransitioning`
/// are released.
struct ActiveTransition {
    let context: UIViewControllerContextTransitioning
    let animationContext: ZoomAnimationContext
    let strategy: ZoomTransitionAnimating
    var transitionAnimator: UIViewPropertyAnimator
    var geometryAnimators: [UIViewPropertyAnimator]
    /// Decremented as each animator completes; the completion barrier fires at 0.
    var pendingAnimatorCount: Int
    var didCleanUp: Bool = false
    let contextInfo: ZoomTransition.Context
    var fallbackReason: ZoomTransition.FallbackReason?

    // MARK: Interactive (M6)

    /// `true` for a gesture-driven run (`ZoomInteractionDriver`); drives `wasInteractive` in the
    /// reported `Result` and selects the self-decided completion flag over the context's.
    var interactive: Bool = false
    /// Bumped on every settle and on every grab. A barrier completion captures the generation live
    /// at the moment it is attached and no-ops if it no longer matches — so the `finishAnimation`
    /// a grab fires on the springs it is freezing can never prematurely trip the barrier (§4/§8).
    var barrierGeneration: Int = 0
    /// The completion flag the *interactive* barrier reports (we decide it at release; the mock
    /// context's `transitionWasCancelled` is not authoritative for a self-driven transition).
    var settleCompleted: Bool = false
}

/// `UIViewControllerAnimatedTransitioning` for a single non-interactive zoom (present/dismiss;
/// push/pop is M4). It owns the *procedure* — state machine, source resolution, the two-animator
/// completion barrier, single-exit cleanup, and `completeTransition` — while a `Strategy`
/// (`ZoomAnimator` or `CrossDissolveAnimator`) owns view scaffolding and animated targets.
///
/// **`interruptibleAnimator(using:)` is deliberately not implemented** (TECH_SPEC §14-1): vending
/// it binds UIKit to the "same animator instance for the transition's lifetime" contract, which
/// collides with M6's grab-driven freeze-and-rebuild. We self-drive the animators instead.
@MainActor
final class TransitionDriver: NSObject, UIViewControllerAnimatedTransitioning {

    let transition: ZoomTransition
    let phase: ZoomTransition.Phase
    let operation: ZoomTransition.Operation

    /// Dimming view the driver creates and owns for the navigation (push/pop) path, where there is
    /// no `ZoomPresentationController` to own one. `nil` on the modal path (the presentation
    /// controller owns dimming there). Removed by `cleanup`.
    private var navigationOwnedDimmingView: UIView?

    init(transition: ZoomTransition, phase: ZoomTransition.Phase, operation: ZoomTransition.Operation) {
        self.transition = transition
        self.phase = phase
        self.operation = operation
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        transition.configuration.spring.response
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let direction: Direction = (phase == .appearing) ? .zoomIn : .zoomOut

        // 1. begin — the adapter's idle guard (§8) is the first line of defence; a rejectBegin
        //    reaching here is a bug, so assert and complete like the system default would.
        let effects = transition.stateMachine.handle(.begin(direction, interactive: false))
        if effects.contains(.rejectBegin) {
            ZoomyAssert.fail("TransitionDriver.animateTransition reached with a non-idle state machine")
            context.completeTransition(true)
            return
        }

        // 2–3. Shared staging (willBegin, source resolution, dimming/backdrop, animation context).
        guard let staged = makeStagedContext(using: context, isInteractive: false) else {
            // Nothing to animate — behave like the system default.
            transition.stateMachine.handle(.allAnimatorsFinished)
            context.completeTransition(true)
            return
        }

        // 4. prepare → makeAnimators.
        staged.strategy.prepare(using: staged.animationContext)
        let (transitionAnimator, geometryAnimators) = staged.strategy.makeAnimators(using: staged.animationContext)

        let active = ActiveTransition(
            context: context,
            animationContext: staged.animationContext,
            strategy: staged.strategy,
            transitionAnimator: transitionAnimator,
            geometryAnimators: geometryAnimators,
            pendingAnimatorCount: 1 + geometryAnimators.count,
            contextInfo: staged.contextInfo,
            fallbackReason: staged.fallbackReason
        )
        transition.activeTransition = active
        transition.currentDriver = self

        // 5. Completion barrier — every animator decrements; the last one fires the barrier.
        let onAnimatorFinished: (UIViewAnimatingPosition) -> Void = { [weak self, weak transition] _ in
            guard let self, let transition, var running = transition.activeTransition, !running.didCleanUp else { return }
            running.pendingAnimatorCount -= 1
            transition.activeTransition = running
            if running.pendingAnimatorCount <= 0 {
                self.completionBarrierFired()
            }
        }
        transitionAnimator.addCompletion(onAnimatorFinished)
        geometryAnimators.forEach { $0.addCompletion(onAnimatorFinished) }

        // 6. Start the geometry animators first so the portal's model bounds are already the
        //    final size when the transition animator's corner-radius clamp reads them.
        active.geometryAnimators.forEach { $0.startAnimation() }
        active.transitionAnimator.startAnimation()
    }

    // MARK: - Interactive setup (M6)

    /// Staging entry point for the `ZoomInteractionDriver`: performs the same source resolution and
    /// view staging as `animateTransition`, but builds only a **paused-at-0 transition animator**
    /// (no geometry — the driver follows the finger directly and springs the geometry at settle).
    /// Begins the state machine interactively only once a real zoom (resolved source) is assured.
    ///
    /// Returns `false` when the source can't be resolved (no portal to fly): the caller falls back
    /// to `animateTransition`, so a drag with a vanished source degrades to a plain animated close
    /// rather than a broken interactive one.
    @discardableResult
    func setUpInteractive(using context: UIViewControllerContextTransitioning) -> Bool {
        guard let staged = makeStagedContext(using: context, isInteractive: true),
              let zoomAnimator = staged.strategy as? ZoomAnimator else {
            return false
        }

        // Only now that a real zoom is assured do we take the state machine interactive.
        let effects = transition.stateMachine.handle(.begin(.zoomOut, interactive: true))
        if effects.contains(.rejectBegin) {
            ZoomyAssert.fail("TransitionDriver.setUpInteractive reached with a non-idle state machine")
            return false
        }

        zoomAnimator.prepareInteractive(using: staged.animationContext)
        let transitionAnimator = zoomAnimator.makeTransitionAnimator(using: staged.animationContext)
        // Move to `.active` and pause at fractionComplete 0 so it can be scrubbed by the follow.
        transitionAnimator.pauseAnimation()

        var active = ActiveTransition(
            context: context,
            animationContext: staged.animationContext,
            strategy: staged.strategy,
            transitionAnimator: transitionAnimator,
            geometryAnimators: [],
            pendingAnimatorCount: 0,
            contextInfo: staged.contextInfo,
            fallbackReason: staged.fallbackReason
        )
        active.interactive = true
        transition.activeTransition = active
        transition.currentDriver = self
        return true
    }

    /// Everything `animateTransition` does between the state-machine `begin` and `prepare`: resolve
    /// the zoomed view, report `willBegin`, resolve/validate the source, pick the strategy and build
    /// geometry, install dimming/backdrop, and assemble the `ZoomAnimationContext`. Shared by the
    /// non-interactive and interactive setup paths. Returns `nil` when there is no view to animate.
    private func makeStagedContext(
        using context: UIViewControllerContextTransitioning,
        isInteractive: Bool
    ) -> (
        animationContext: ZoomAnimationContext,
        strategy: ZoomTransitionAnimating,
        contextInfo: ZoomTransition.Context,
        fallbackReason: ZoomTransition.FallbackReason?
    )? {
        let container = context.containerView

        // The "zoomed" side is the destination on the way in, the departing VC on the way out.
        let zoomedVC: UIViewController?
        let presenterVC: UIViewController?
        switch phase {
        case .appearing:
            zoomedVC = context.viewController(forKey: .to)
            presenterVC = context.viewController(forKey: .from)
        case .disappearing:
            zoomedVC = context.viewController(forKey: .from)
            presenterVC = context.viewController(forKey: .to)
        }

        guard let zoomedViewController = zoomedVC,
              let zoomedView = view(for: zoomedViewController, phase: phase, context: context) else {
            return nil
        }

        let contextInfo = ZoomTransition.Context(
            zoomedViewController: zoomedViewController,
            sourceViewController: presenterVC,
            phase: phase,
            operation: operation,
            isInteractive: isInteractive
        )

        // willBegin — reported *before* source resolution so the app can restore layout.
        transition.reportWillBegin(contextInfo)

        let finalFrame = context.finalFrame(for: zoomedViewController)

        // Source resolution → pick strategy + build geometry.
        let resolution = SourceViewResolver.resolve(
            provider: transition.sourceViewProvider,
            context: contextInfo,
            zoomedView: zoomedView,
            containerView: container
        )

        let strategy: ZoomTransitionAnimating
        var resolvedSource: ResolvedSource?
        var geometry: ZoomGeometry?
        var fallbackReason: ZoomTransition.FallbackReason?

        switch resolution {
        case .success(let source):
            resolvedSource = source
            geometry = ZoomGeometry(
                sourceRect: source.rectInContainer,
                sourceVisibleRect: source.visibleRectInContainer,
                finalRect: finalFrame,
                sourceCornerRadius: startCornerRadius(for: source, container: container),
                finalCornerRadius: finalCornerRadius(container: container)
            )
            strategy = ZoomAnimator()
        case .failure(let reason):
            fallbackReason = .sourceUnresolved
            strategy = CrossDissolveAnimator()
            #if DEBUG
            os_log(
                "ZoomTransition source resolution failed (%{public}@) — falling back to cross-dissolve",
                log: .zoomy,
                type: .debug,
                String(describing: reason)
            )
            #endif
        }

        let presentedVC = zoomedViewController
        let presenterView = (presentedVC.modalPresentationStyle == .custom) ? presenterVC?.view : nil
        let backgroundView: UIView? = (phase == .disappearing) ? context.view(forKey: .to) : nil

        // Dimming: the modal path reads it from the presentation controller; the navigation path
        // has none, so the driver builds and owns one (and, on pop, seats the revealed view behind
        // the departing one). See `installNavigationBackdrop`.
        let dimmingView: UIView?
        switch operation {
        case .push, .pop:
            dimmingView = installNavigationBackdrop(container: container, context: context)
            navigationOwnedDimmingView = dimmingView
        case .present, .dismiss:
            dimmingView = (presentedVC.presentationController as? ZoomPresentationController)?.dimmingView
        }

        let animationContext = ZoomAnimationContext(
            containerView: container,
            phase: phase,
            zoomedView: zoomedView,
            zoomedViewController: zoomedViewController,
            backgroundView: backgroundView,
            resolvedSource: resolvedSource,
            geometry: geometry,
            configuration: transition.configuration,
            restorationToken: RestorationToken(),
            dimmingView: dimmingView,
            presenterView: presenterView,
            portal: PortalView(frame: .zero),
            finalFrame: finalFrame
        )

        return (animationContext, strategy, contextInfo, fallbackReason)
    }

    /// UIKit's teardown hook. In the normal path the barrier has already cleaned up (guarded by
    /// `didCleanUp`); this is the abandoned-context backstop (TECH_SPEC §5.6 / §7.9). Full
    /// forceFinish (gesture flush, animator fast-forward) is M7.
    func animationEnded(_ transitionCompleted: Bool) {
        guard let active = transition.activeTransition, !active.didCleanUp else { return }
        transition.stateMachine.handle(.forceFinish(.abandoned))
        let contextInfo = active.contextInfo
        let fallbackReason = active.fallbackReason
        cleanup(finished: transitionCompleted)
        transition.reportDidEnd(
            contextInfo,
            result: ZoomTransition.Result(
                isCompleted: transitionCompleted,
                wasInteractive: false,
                fallbackReason: fallbackReason
            )
        )
    }

    // MARK: - Barrier / cleanup

    private func completionBarrierFired() {
        guard let active = transition.activeTransition, !active.didCleanUp else { return }
        let context = active.context
        let contextInfo = active.contextInfo
        let fallbackReason = active.fallbackReason
        let completed = !context.transitionWasCancelled

        transition.stateMachine.handle(.allAnimatorsFinished)
        cleanup(finished: completed)
        context.completeTransition(completed)
        transition.reportDidEnd(
            contextInfo,
            result: ZoomTransition.Result(
                isCompleted: completed,
                wasInteractive: false,
                fallbackReason: fallbackReason
            )
        )
    }

    /// Single exit (TECH_SPEC §7.9): strategy teardown → token restore → a11y announce → drop
    /// the active transition. Idempotent via `didCleanUp`. The caller performs
    /// `completeTransition` / `reportDidEnd` afterwards. Reused by `ZoomInteractionDriver` for the
    /// interactive settle so both paths share one teardown (and one `navigationOwnedDimmingView`
    /// owner).
    func cleanup(finished: Bool) {
        guard var active = transition.activeTransition, !active.didCleanUp else { return }
        active.didCleanUp = true
        transition.activeTransition = active

        active.strategy.finish(using: active.animationContext, completed: finished)
        active.animationContext.restorationToken.restore()
        // The navigation path's dimming view is driver-owned scaffolding (the modal path's belongs
        // to the presentation controller and is torn down there); remove it here.
        navigationOwnedDimmingView?.removeFromSuperview()
        navigationOwnedDimmingView = nil
        UIAccessibility.post(notification: .screenChanged, argument: nil)

        transition.activeTransition = nil
        transition.currentDriver = nil
    }

    // MARK: - Helpers

    /// Prepares the container backdrop for a push/pop, standing in for the `ZoomPresentationController`
    /// the navigation path doesn't have:
    /// - On pop, seats the revealed (destination) view beneath the departing view so the shrinking
    ///   portal lands over real content instead of an empty container.
    /// - Creates the dimming view (from `configuration.dimmingColor`) the transition animator drives,
    ///   inserted above the background content but below the portal `prepare` adds next.
    ///
    /// Returns the dimming view (`nil` when `dimmingColor` is `nil`), which the caller records for
    /// removal in `cleanup`.
    private func installNavigationBackdrop(
        container: UIView,
        context: UIViewControllerContextTransitioning
    ) -> UIView? {
        // Pop: place the revealed view under the departing one.
        if phase == .disappearing,
           let toVC = context.viewController(forKey: .to),
           let toView = context.view(forKey: .to),
           toView.superview !== container {
            toView.frame = context.finalFrame(for: toVC)
            container.insertSubview(toView, at: 0)
        }

        guard let color = transition.configuration.dimmingColor else { return nil }

        let dimming = UIView()
        dimming.backgroundColor = color
        dimming.alpha = (phase == .appearing) ? 0 : 1
        dimming.frame = container.bounds
        dimming.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Seat the dimming view directly above the background content it should darken.
        let backdropKey: UITransitionContextViewKey = (phase == .appearing) ? .from : .to
        if let backdrop = context.view(forKey: backdropKey), backdrop.superview === container {
            container.insertSubview(dimming, aboveSubview: backdrop)
        } else {
            container.insertSubview(dimming, at: 0)
        }
        return dimming
    }

    private func view(
        for viewController: UIViewController,
        phase: ZoomTransition.Phase,
        context: UIViewControllerContextTransitioning
    ) -> UIView? {
        let key: UITransitionContextViewKey = (phase == .appearing) ? .to : .from
        return context.view(forKey: key) ?? viewController.view
    }

    /// The corner radius the portal starts the *appearing* morph from (and ends the disappearing
    /// morph at): the source's own radius under `.automatic`, the configured `from` under
    /// `.fixed`, 0 under `.none`.
    private func startCornerRadius(for source: ResolvedSource, container: UIView) -> CGFloat {
        switch transition.configuration.cornerMorph {
        case .automatic: return source.cornerRadius
        case .fixed(let from, _): return from
        case .none: return 0
        }
    }

    /// The corner radius the portal ends the *appearing* morph at (and starts the disappearing
    /// morph from) — the container's contextual radius under `.automatic`, the configured `to`
    /// under `.fixed`, 0 under `.none`.
    private func finalCornerRadius(container: UIView) -> CGFloat {
        switch transition.configuration.cornerMorph {
        case .automatic: return ContainerCornerRadius.automaticFinalRadius(for: container)
        case .fixed(_, let to): return to
        case .none: return 0
        }
    }
}
