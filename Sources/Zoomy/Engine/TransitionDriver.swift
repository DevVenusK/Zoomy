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

/// The result of `makeStagedContext`: the staged views plus the chosen strategy. Passed to
/// `runNonInteractive` so an interactive setup that falls back can flow into the shared
/// non-interactive run **on the already-staged context** — staging (and therefore `willBegin` +
/// the nav backdrop) happens exactly once (M6 review I2).
struct StagedContext {
    let animationContext: ZoomAnimationContext
    let strategy: ZoomTransitionAnimating
    let contextInfo: ZoomTransition.Context
    let fallbackReason: ZoomTransition.FallbackReason?
}

/// The outcome of `setUpInteractive`, so `startInteractiveTransition` knows whether a follow will
/// drive the transition, whether it already ran to completion non-interactively (fallback), or
/// whether there was nothing to stage.
enum InteractiveSetupResult {
    /// Staged interactively; the follow will drive update/settle.
    case interactive
    /// The strategy was a fallback (unresolvable source / Reduce Motion): the transition is already
    /// animating to completion non-interactively on the single staged context. Nothing to follow.
    case ranNonInteractive
    /// There was no view to stage; the caller must complete the (empty) transition.
    case notStaged
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

    /// When non-nil, the driver skips source resolution and runs the `CrossDissolveAnimator` with
    /// this reason (M7 §9: Reduce Motion / VoiceOver). Decided at vend time by the adapter /
    /// nav-delegate so a mid-run accessibility toggle never changes an in-flight transition.
    let forcedFallbackReason: ZoomTransition.FallbackReason?

    /// Dimming view the driver creates and owns for the navigation (push/pop) path, where there is
    /// no `ZoomPresentationController` to own one. `nil` on the modal path (the presentation
    /// controller owns dimming there). Removed by `cleanup`.
    private var navigationOwnedDimmingView: UIView?

    /// Zero-footprint sentinel installed in the container for a push/pop so a container bounds change
    /// (rotation / split-view resize) can `forceFinish(.sizeChange)` without swizzling (§7.10). The
    /// modal path uses `ZoomPresentationController.viewWillTransition` instead. Removed by `cleanup`.
    private var layoutSentinel: LayoutSentinelView?

    /// Observes `UIScene.didEnterBackgroundNotification` filtered to the container's window scene, to
    /// `forceFinish(.sceneBackground)` an in-flight transition (§7.10). Released with the driver.
    private var backgroundObserver: SceneBackgroundObserver?

    /// Bar snapshot coordinator for push/pop (§7.8): fades a `hidesBottomBarWhenPushed` tab bar /
    /// toolbar across the transition. `nil` on the modal path and when no bar needs hiding.
    private var barSnapshotController: BarSnapshotController?

    init(
        transition: ZoomTransition,
        phase: ZoomTransition.Phase,
        operation: ZoomTransition.Operation,
        forcedFallbackReason: ZoomTransition.FallbackReason? = nil
    ) {
        self.transition = transition
        self.phase = phase
        self.operation = operation
        self.forcedFallbackReason = forcedFallbackReason
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

        // 4–6. Prepare, build animators, install the barrier, and start.
        runNonInteractive(staged: staged, context: context)
    }

    /// Steps 4–6 of a non-interactive run on an **already-staged** context: prepare, install push/pop
    /// scaffolding, build the animators, wire the generation-guarded completion barrier, and start.
    /// Shared by `animateTransition` and by `setUpInteractive`'s fallback so the interactive→fallback
    /// path stages exactly once (no duplicate `willBegin` / leaked dimming — M6 review I2).
    private func runNonInteractive(staged: StagedContext, context: UIViewControllerContextTransitioning) {
        // 4. prepare → (push/pop) bar snapshot + bounds sentinel below the portal → makeAnimators.
        staged.strategy.prepare(using: staged.animationContext)
        installPushPopScaffolding(using: staged.animationContext)
        let (transitionAnimator, geometryAnimators) = staged.strategy.makeAnimators(using: staged.animationContext)
        barSnapshotController?.addFade(to: transitionAnimator, phase: phase)

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

        // 5. Completion barrier — every animator decrements; the last one fires the barrier. The
        //    generation captured here (0 for a fresh non-interactive run) is re-checked in the
        //    completion so a `forceFinish` that stops these animators — bumping the generation first —
        //    makes their synchronous completions no-op instead of double-firing the barrier (§7.10).
        let generation = active.barrierGeneration
        let onAnimatorFinished: (UIViewAnimatingPosition) -> Void = { [weak self, weak transition] _ in
            guard let self, let transition, var running = transition.activeTransition, !running.didCleanUp,
                  running.barrierGeneration == generation else { return }
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
    /// When the strategy is a fallback (source can't be resolved / Reduce Motion), there is no
    /// portal to fly interactively, so it flows into the shared non-interactive run **on the same
    /// staged context** (`.ranNonInteractive`) — staging happens exactly once, so `willBegin` fires
    /// once and no second nav dimming view leaks (M6 review I2). Returns `.notStaged` when there was
    /// nothing to stage.
    func setUpInteractive(using context: UIViewControllerContextTransitioning) -> InteractiveSetupResult {
        guard let staged = makeStagedContext(using: context, isInteractive: true) else {
            return .notStaged
        }

        guard let zoomAnimator = staged.strategy as? ZoomAnimator else {
            // Fallback strategy: run the plain animated close on the already-staged context.
            let effects = transition.stateMachine.handle(.begin(.zoomOut, interactive: false))
            if effects.contains(.rejectBegin) {
                ZoomyAssert.fail("TransitionDriver.setUpInteractive reached with a non-idle state machine")
                return .notStaged
            }
            runNonInteractive(staged: staged, context: context)
            return .ranNonInteractive
        }

        // Only now that a real zoom is assured do we take the state machine interactive.
        let effects = transition.stateMachine.handle(.begin(.zoomOut, interactive: true))
        if effects.contains(.rejectBegin) {
            ZoomyAssert.fail("TransitionDriver.setUpInteractive reached with a non-idle state machine")
            return .notStaged
        }

        zoomAnimator.prepareInteractive(using: staged.animationContext)
        installPushPopScaffolding(using: staged.animationContext)
        let transitionAnimator = zoomAnimator.makeTransitionAnimator(using: staged.animationContext)
        barSnapshotController?.addFade(to: transitionAnimator, phase: phase)
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
        return .interactive
    }

    /// Everything `animateTransition` does between the state-machine `begin` and `prepare`: resolve
    /// the zoomed view, report `willBegin`, resolve/validate the source, pick the strategy and build
    /// geometry, install dimming/backdrop, and assemble the `ZoomAnimationContext`. Shared by the
    /// non-interactive and interactive setup paths. Returns `nil` when there is no view to animate.
    private func makeStagedContext(
        using context: UIViewControllerContextTransitioning,
        isInteractive: Bool
    ) -> StagedContext? {
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

        // Force-finish an in-flight transition when the scene backgrounds (§7.10); filtered to the
        // container's window scene so an unrelated scene's notification is ignored (iPad multiwindow).
        backgroundObserver = SceneBackgroundObserver(scene: container.window?.windowScene) { [weak self] in
            self?.forceFinish(.sceneBackground)
        }

        let finalFrame = context.finalFrame(for: zoomedViewController)

        let strategy: ZoomTransitionAnimating
        var resolvedSource: ResolvedSource?
        var geometry: ZoomGeometry?
        var fallbackReason: ZoomTransition.FallbackReason?

        if let forced = forcedFallbackReason {
            // §9: Reduce Motion / VoiceOver — run the cross-dissolve, never resolving a source.
            fallbackReason = forced
            strategy = CrossDissolveAnimator()
        } else {
            // §5: on a dismiss/pop, force the presenter's layout before resolving the source so a
            // rotation-while-presented can't leave the source view at a stale frame. On a nav *pop*
            // the revealed destination isn't in the window yet, so its source view would resolve as
            // `.detached` and the pop would fall back to a cross-dissolve instead of zooming home —
            // seat it in the container first so the source has a window. (Modal dismiss doesn't need
            // this: the presenter's view stays in the window via `shouldRemovePresentersView`.)
            if phase == .disappearing {
                if operation == .pop {
                    seatRevealedPopDestination(container: container, context: context)
                }
                (context.view(forKey: .to) ?? presenterVC?.view)?.layoutIfNeeded()
            }

            // Source resolution → pick strategy + build geometry.
            let resolution = SourceViewResolver.resolve(
                provider: transition.sourceViewProvider,
                context: contextInfo,
                zoomedView: zoomedView,
                containerView: container
            )

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

        return StagedContext(
            animationContext: animationContext,
            strategy: strategy,
            contextInfo: contextInfo,
            fallbackReason: fallbackReason
        )
    }

    /// UIKit's teardown hook. In the normal path the barrier has already cleaned up (guarded by
    /// `didCleanUp`); this is the abandoned-context backstop (TECH_SPEC §5.6 / §7.9). UIKit has
    /// already called `completeTransition` by the time it invokes this, so — unlike `forceFinish` —
    /// this path never calls it again; it only cleans up and reports.
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

    // MARK: - Force finish (§7.10)

    /// Fast-forwards an in-flight transition to a clean completion when the container geometry changes
    /// (rotation / size class) or the scene backgrounds — never leaving the zoom stranded mid-flight.
    /// Drives both the non-interactive and interactive paths (it reads the shared `ActiveTransition`),
    /// and is a no-op once the transition has finished (`activeTransition == nil`).
    ///
    /// **Barrier safety (the load-bearing invariant).** Stopping a `UIViewPropertyAnimator` fires its
    /// completion **synchronously**. So — exactly as M6's grab does — we publish a *bumped generation*
    /// and a cleared pending count *before* stopping any animator; both barriers re-check the
    /// generation, so those synchronous completions no-op instead of tripping `completeTransition` a
    /// second time. We then run the single-exit `cleanup` and call `completeTransition` / `reportDidEnd`
    /// exactly once, ourselves.
    func forceFinish(_ reason: ForceReason) {
        guard var active = transition.activeTransition, !active.didCleanUp else { return }

        let priorState = transition.stateMachine.state
        let effects = transition.stateMachine.handle(.forceFinish(reason))
        // Idle (or an unexpected no-op transition) means there is nothing in flight to force.
        guard !effects.isEmpty else { return }
        var completed = true
        for effect in effects {
            if case .cleanupAndComplete(let value) = effect { completed = value }
        }

        let context = active.context
        let contextInfo = active.contextInfo
        let fallbackReason = active.fallbackReason
        let wasInteractive = active.interactive

        // 1. Flush any interactive pan/edge recognizer so a stranded gesture can't re-drive this.
        transition.interactionDriver?.flushGestures()

        // 2. If we were mid-scrub (interactive), commit the direction to UIKit now. A `.settling`
        //    run already called finish/cancelInteractiveTransition at release, so it must not repeat.
        if case .interactive = priorState {
            if completed { context.finishInteractiveTransition() } else { context.cancelInteractiveTransition() }
        }

        // 3. Publish the bumped generation + cleared count BEFORE stopping animators, so their
        //    synchronous completions no-op against the barrier (see the method doc).
        let transitionAnimator = active.transitionAnimator
        let geometryAnimators = active.geometryAnimators
        active.barrierGeneration += 1
        active.pendingAnimatorCount = 0
        active.geometryAnimators = []
        transition.activeTransition = active

        // 4. Stop every *live* animator (guarded by state — `.inactive`/already-`.stopped` are skipped
        //    so `finishAnimation` never throws). `.current` avoids the reversed-animator position
        //    ambiguity; `cleanup` re-stamps the live view to its resting frame regardless.
        fastForward(transitionAnimator)
        for spring in geometryAnimators { fastForward(spring) }

        // 5. Single-exit teardown, then complete + report exactly once.
        cleanup(finished: completed)
        context.completeTransition(completed)
        transition.reportDidEnd(
            contextInfo,
            result: ZoomTransition.Result(
                isCompleted: completed,
                wasInteractive: wasInteractive,
                fallbackReason: fallbackReason
            )
        )
    }

    /// Stops and releases a single animator if (and only if) it is live, matching §7.10 step 3.
    private func fastForward(_ animator: UIViewPropertyAnimator) {
        switch animator.state {
        case .active:
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
        case .stopped:
            animator.finishAnimation(at: .current)
        default:
            break // `.inactive` — nothing to stop.
        }
    }

    /// Installs the push/pop-only scaffolding that must sit *below* the portal `prepare` just added:
    /// the bar snapshot (§7.8) and the container bounds-change sentinel (§7.10). No-op for modal
    /// (the presentation controller owns dimming and drives forceFinish from `viewWillTransition`).
    private func installPushPopScaffolding(using context: ZoomAnimationContext) {
        guard operation == .push || operation == .pop else { return }
        let container = context.containerView
        let portal = context.portal

        // Bar snapshot: only the detail's bottom bar (tab bar) needs hiding, and only when the detail
        // requests it. Toolbar handled the same way when visible.
        let detail = context.zoomedViewController
        let tabBar = detail.hidesBottomBarWhenPushed ? detail.tabBarController?.tabBar : nil
        let toolbar: UIToolbar? = {
            guard let nav = detail.navigationController, !nav.isToolbarHidden else { return nil }
            return nav.toolbar
        }()
        if tabBar != nil || toolbar != nil {
            let controller = BarSnapshotController()
            controller.install(
                phase: phase,
                container: container,
                tabBar: tabBar,
                toolbar: toolbar,
                belowPortal: portal,
                token: context.restorationToken
            )
            barSnapshotController = controller
        }

        // Bounds sentinel: a container resize (rotation / split-view) force-finishes the flight.
        let sentinel = LayoutSentinelView(frame: container.bounds) { [weak self] in
            guard let self, self.transition.activeTransition != nil else { return }
            self.forceFinish(.sizeChange)
        }
        container.insertSubview(sentinel, at: 0)
        layoutSentinel = sentinel
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
        // to the presentation controller and is torn down there); remove it here. Bar snapshots and
        // the bounds sentinel are always driver-owned.
        navigationOwnedDimmingView?.removeFromSuperview()
        navigationOwnedDimmingView = nil
        barSnapshotController?.removeSnapshots()
        barSnapshotController = nil
        layoutSentinel?.removeFromSuperview()
        layoutSentinel = nil

        // Announce the screen the user arrives on so VoiceOver moves focus there (§9): the live view
        // when it stays/arrives, the revealed background when we leave; `nil` lets VoiceOver choose.
        UIAccessibility.post(notification: .screenChanged, argument: screenChangeTarget(active: active, finished: finished))

        transition.activeTransition = nil
        transition.currentDriver = nil
    }

    /// The representative element for the post-transition `.screenChanged` announcement (§9).
    private func screenChangeTarget(active: ActiveTransition, finished: Bool) -> UIView? {
        let arrivedAtLiveView = (phase == .appearing) == finished
        if arrivedAtLiveView { return active.animationContext.zoomedView }
        return active.animationContext.backgroundView ?? active.animationContext.presenterView
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
        // Pop: place the revealed view under the departing one. Usually already seated before source
        // resolution (see `seatRevealedPopDestination`); this covers the forced-fallback pop, which
        // skips resolution. Idempotent via the helper's `superview` guard.
        seatRevealedPopDestination(container: container, context: context)

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

    /// Seats the revealed destination view at the bottom of the container on a pop, giving the source
    /// view it hosts a window *before* source resolution. Without this the source resolves as
    /// `.detached` and the pop falls back to a cross-dissolve instead of zooming to the source cell
    /// (nav pop only — modal dismiss keeps its presenter in the window already). Idempotent: guarded
    /// on `superview !== container`, so calling it both pre-resolution and from `installNavigationBackdrop`
    /// (the forced-fallback path) seats the view exactly once. No-op for an appearing phase.
    private func seatRevealedPopDestination(
        container: UIView,
        context: UIViewControllerContextTransitioning
    ) {
        guard phase == .disappearing,
              let toVC = context.viewController(forKey: .to),
              let toView = context.view(forKey: .to),
              toView.superview !== container else { return }
        toView.frame = context.finalFrame(for: toVC)
        container.insertSubview(toView, at: 0)
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
