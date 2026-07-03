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

    private let transition: ZoomTransition
    private let phase: ZoomTransition.Phase
    private let operation: ZoomTransition.Operation

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
            // Nothing to animate — behave like the system default.
            transition.stateMachine.handle(.allAnimatorsFinished)
            context.completeTransition(true)
            return
        }

        let contextInfo = ZoomTransition.Context(
            zoomedViewController: zoomedViewController,
            sourceViewController: presenterVC,
            phase: phase,
            operation: operation,
            isInteractive: false
        )

        // 2. willBegin — reported *before* source resolution so the app can restore layout.
        transition.reportWillBegin(contextInfo)

        let finalFrame = context.finalFrame(for: zoomedViewController)

        // 3. Source resolution → pick strategy + build geometry.
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
        let dimmingView = (presentedVC.presentationController as? ZoomPresentationController)?.dimmingView
        let presenterView = (presentedVC.modalPresentationStyle == .custom) ? presenterVC?.view : nil
        let backgroundView: UIView? = (phase == .disappearing) ? context.view(forKey: .to) : nil

        let portal = PortalView(frame: .zero)
        let token = RestorationToken()

        let animationContext = ZoomAnimationContext(
            containerView: container,
            phase: phase,
            zoomedView: zoomedView,
            zoomedViewController: zoomedViewController,
            backgroundView: backgroundView,
            resolvedSource: resolvedSource,
            geometry: geometry,
            configuration: transition.configuration,
            restorationToken: token,
            dimmingView: dimmingView,
            presenterView: presenterView,
            portal: portal,
            finalFrame: finalFrame
        )

        // 4. prepare → makeAnimators.
        strategy.prepare(using: animationContext)
        let (transitionAnimator, geometryAnimators) = strategy.makeAnimators(using: animationContext)

        let active = ActiveTransition(
            context: context,
            animationContext: animationContext,
            strategy: strategy,
            transitionAnimator: transitionAnimator,
            geometryAnimators: geometryAnimators,
            pendingAnimatorCount: 1 + geometryAnimators.count,
            contextInfo: contextInfo,
            fallbackReason: fallbackReason
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
    /// `completeTransition` / `reportDidEnd` afterwards.
    private func cleanup(finished: Bool) {
        guard var active = transition.activeTransition, !active.didCleanUp else { return }
        active.didCleanUp = true
        transition.activeTransition = active

        active.strategy.finish(using: active.animationContext, completed: finished)
        active.animationContext.restorationToken.restore()
        UIAccessibility.post(notification: .screenChanged, argument: nil)

        transition.activeTransition = nil
        transition.currentDriver = nil
    }

    // MARK: - Helpers

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
