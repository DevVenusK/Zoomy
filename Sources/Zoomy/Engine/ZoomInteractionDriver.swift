import UIKit

/// The interactive dismiss/pop engine (TECH_SPEC §5.7 / §7.6 / §7.7): a custom
/// `UIViewControllerInteractiveTransitioning` that follows the finger to shrink the destination
/// toward its source, then springs it the rest of the way home (dismiss/pop) or back (cancel) on
/// release — scrubbable, cancellable, and re-grabbable mid-settle.
///
/// ### The three decisions (§1)
/// 1. **Dynamic `wantsInteractiveStart`** — `true` when a pan is already driving the dismissal
///    (gesture-initiated), `false` when vended so a tap-initiated present can be grabbed mid-flight.
/// 2. **Custom interactive transitioning** — never `UIPercentDrivenInteractiveTransition`. On
///    `startInteractiveTransition` it stages the transition and builds the transition animator
///    *paused at 0* (no geometry), then self-drives update/finish/cancel.
/// 3. **Two-animator barrier preserved** — the scrub/reverse-safe transition animator stays paused
///    through the follow; at settle a *fresh* geometry spring is created and the last animator to
///    finish fires the single `completeTransition` (3b's barrier contract, here generation-guarded
///    so a grab can freeze a spring without tripping it — §4/§8).
///
/// **`interruptibleAnimator(using:)` is never implemented** (it would bind UIKit to one animator
/// instance and collide with the freeze-and-rebuild grab). Reverse-running animators are never
/// scrubbed — they are stopped and rebuilt (§4).
///
/// Setup, the completion barrier's teardown, and the `Result` reporting are delegated to the linked
/// non-interactive `TransitionDriver` (`animationDriver`) so both paths share one code path; this
/// object owns only the follow/settle/grab orchestration on top.
@MainActor
final class ZoomInteractionDriver: NSObject, UIViewControllerInteractiveTransitioning {

    unowned let transition: ZoomTransition
    /// Always `.disappearing` — the interactive engine only drives dismiss/pop.
    let phase: ZoomTransition.Phase
    /// `.dismiss` (modal) or `.pop` (navigation).
    let operation: ZoomTransition.Operation

    /// `true` when a pan is already driving this transition (set by the adapter/nav-delegate when
    /// the gesture is active at vend time), `false` when vended to legalise a mid-present grab.
    @objc var wantsInteractiveStart: Bool = false

    /// Installed on the destination's root view once it finishes appearing (see `installGesture`).
    let panGesture: UIPanGestureRecognizer

    /// An *external* pan recognizer currently allowed to drive this same interaction — M5's
    /// left-edge `UIScreenEdgePanGestureRecognizer` installed on the navigation view. Held `weak`
    /// (the nav view owns the recognizer; the M5 coordinator owns its dispatch and calls
    /// `handlePan(_:)` directly). `isGestureActive` consults it so a pop that an edge swipe initiates
    /// is recognised as gesture-driven at vend time, exactly like the built-in `panGesture`.
    private weak var externalDrivingGesture: UIPanGestureRecognizer?

    /// The non-interactive driver UIKit vended for this transition; reused for staging
    /// (`setUpInteractive`) and the shared single-exit `cleanup`. Retained for the transition's
    /// duration by `transition.currentDriver`, so a `weak` reference here forms no cycle.
    weak var animationDriver: TransitionDriver?

    // MARK: Follow state

    /// Seeded from the staged portal at start and re-seeded from the portal's live position on grab.
    private var follow: FollowModel?
    /// Global progress at the most recent grab (0 at start): the follow resumes from here so
    /// position *and* scale stay continuous across a re-grab. Also the remap base for a rebuilt
    /// transition animator.
    private var baseProgress: CGFloat = 0
    /// Remap base applied to the transition animator's `fractionComplete`: 0 while the animator
    /// spans the full [start → complete] range (initial follow, or a scrub-safe forward re-grab),
    /// and `baseProgress` after a reversed animator was stopped and rebuilt fresh (§4 rule 2).
    private var transitionBaseFraction: CGFloat = 0
    /// The most recent release velocity, forwarded to the settle spring.
    private var lastGestureVelocity: CGPoint = .zero

    init(transition: ZoomTransition, phase: ZoomTransition.Phase, operation: ZoomTransition.Operation) {
        self.transition = transition
        self.phase = phase
        self.operation = operation
        self.panGesture = UIPanGestureRecognizer()
        super.init()
        panGesture.addTarget(self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        panGesture.maximumNumberOfTouches = 1
    }

    /// Installs the pan recognizer on the destination's root view (idempotent). Called once the
    /// destination has finished appearing (modal: `presentationTransitionDidEnd`; nav: `didShow`).
    /// Under VoiceOver the recognizer is installed **disabled** (§9): interactive dismissal is
    /// suppressed so a swipe never fights VoiceOver's own gestures; the non-interactive cross-dissolve
    /// path handles the dismissal instead.
    func installGesture(on view: UIView) {
        guard panGesture.view !== view else { return }
        view.addGestureRecognizer(panGesture)
        panGesture.isEnabled = !transition.suppressesInteractionForAccessibility
    }

    /// Flushes our recognizers (`isEnabled` toggle) so an in-flight gesture is cancelled before a
    /// `forceFinish` fast-forwards the transition (§7.10 step 1). Restores the prior enabled state so
    /// a VoiceOver-disabled pan stays disabled.
    func flushGestures() {
        let wasEnabled = panGesture.isEnabled
        panGesture.isEnabled = false
        panGesture.isEnabled = wasEnabled
        if let external = externalDrivingGesture {
            let externalEnabled = external.isEnabled
            external.isEnabled = false
            external.isEnabled = externalEnabled
        }
    }

    /// `true` while the pan is actually driving a dismissal — the signal the adapter/nav-delegate
    /// use to decide interactive vs. non-interactive at vend time (a programmatic `dismiss` leaves
    /// the recognizer idle, so §5's non-interactive path runs). Considers both the built-in
    /// `panGesture` and any registered external driver (M5's edge pan), so an edge-swipe-initiated
    /// pop is vended interactively too.
    var isGestureActive: Bool {
        isActive(panGesture) || isActive(externalDrivingGesture)
    }

    private func isActive(_ gesture: UIGestureRecognizer?) -> Bool {
        guard let gesture else { return false }
        return gesture.state == .began || gesture.state == .changed
    }

    /// Lets an external recognizer (M5's navigation-view left-edge screen-edge pan) drive this
    /// interaction through the *same* `handlePan` settle/grab/barrier path. The caller (the edge-pop
    /// coordinator) owns the recognizer's placement, `shouldBegin` gating, and dispatch — it routes
    /// updates in by calling `handlePan(_:)` directly. This only teaches `isGestureActive` to see the
    /// gesture so `interactionControllerFor` pairs the interactive driver at vend time. The reference
    /// is `weak`, so no retain cycle with the nav view that owns the recognizer.
    func registerExternalDrivingGesture(_ gesture: UIPanGestureRecognizer) {
        externalDrivingGesture = gesture
    }

    // MARK: - UIViewControllerInteractiveTransitioning

    func startInteractiveTransition(_ context: UIViewControllerContextTransitioning) {
        guard let animationDriver else {
            // No driver to stage with — complete so UIKit isn't left waiting.
            context.completeTransition(!context.transitionWasCancelled)
            return
        }

        // Defensive: if a presentation is ever routed through us (present-grab wiring), we cannot
        // interactively drive an *appearing* zoom here — run the normal animated present instead.
        if context.viewController(forKey: .to) === transition.attachedViewController {
            animationDriver.animateTransition(using: context)
            return
        }

        // Interactive staging + a paused-at-0 transition animator. If the source has vanished there
        // is no portal to fly, so `setUpInteractive` itself runs the plain animated close on the
        // single staged context (the drag becomes inert) — staging happens exactly once, so no
        // duplicate `willBegin` or leaked dimming (M6 review I2).
        switch animationDriver.setUpInteractive(using: context) {
        case .interactive:
            lockTopScrollViewIfNeeded()
            seedFollowModel()
            if !wantsInteractiveStart {
                // Vended for a mid-flight grab: hold at the start until a gesture takes over.
                context.pauseInteractiveTransition()
            }
        case .ranNonInteractive:
            // Already animating to completion on the staged context — nothing to follow.
            break
        case .notStaged:
            // No view to stage — complete so UIKit isn't left waiting.
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    // MARK: - Gesture handling

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            handlePanBegan(gesture)
        case .changed:
            handlePanChanged(gesture)
        case .ended, .cancelled, .failed:
            handlePanEnded(gesture)
        default:
            break
        }
    }

    private func handlePanBegan(_ gesture: UIPanGestureRecognizer) {
        switch transition.stateMachine.state {
        case .idle:
            // Gesture-initiated dismissal. `wantsInteractiveStart` is *not* gated on here: it is
            // only turned on when the adapter/nav-delegate vend the driver, and that vend happens
            // *inside* `triggerDismissal`'s `dismiss()`/`pop()` — so gating begin on it would be a
            // chicken-and-egg deadlock (the flag can never be true before the drag it enables).
            // Legitimacy is already guaranteed by `gestureRecognizerShouldBegin` (downward-from-top,
            // scroll-at-top, not VoiceOver-suppressed). Triggering the dismissal makes the gesture
            // active, so the vend then sees `isGestureActive == true` and drives interactively.
            if transition.configuration.resignsFirstResponders {
                gesture.view?.endEditing(true)
            }
            triggerDismissal()
            gesture.setTranslation(.zero, in: gesture.view)
        case .animating, .settling:
            // Mid-flight or settle-time re-grab: freeze the springs, rebuild if reversed, follow.
            performGrab(gesture)
        case .interactive:
            break // already following — ignore a stray began
        }
    }

    private func handlePanChanged(_ gesture: UIPanGestureRecognizer) {
        guard let follow,
              let active = transition.activeTransition, !active.didCleanUp,
              let zoomAnimator = active.strategy as? ZoomAnimator else { return }

        let translation = gesture.translation(in: gesture.view)
        let localProgress = follow.progress(for: translation)
        let globalProgress = baseProgress + localProgress * (1 - baseProgress)

        // Portal follows the finger directly (§2 .changed): scale/center/corner, no animator.
        zoomAnimator.applyInteractiveFollow(
            using: active.animationContext,
            scale: follow.scale(forProgress: globalProgress),
            center: follow.center(for: translation),
            cornerProgress: follow.cornerProgress(forProgress: globalProgress)
        )

        // Transition animator scrubbed linearly, capped just short of the end (§2), remapped onto a
        // rebuilt animator when a reversed one was replaced on grab.
        active.transitionAnimator.fractionComplete = min(
            AnimatorFractionRemap.remap(progress: globalProgress, base: transitionBaseFraction),
            0.995
        )

        active.context.updateInteractiveTransition(globalProgress)
        transition.stateMachine.handle(.update(globalProgress))
    }

    private func handlePanEnded(_ gesture: UIPanGestureRecognizer) {
        guard let follow, transition.activeTransition != nil else { return }

        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        lastGestureVelocity = velocity

        let localProgress = follow.progress(for: translation)
        let globalProgress = baseProgress + localProgress * (1 - baseProgress)
        let completed = follow.shouldComplete(progress: globalProgress, velocity: velocity, translation: translation)

        transition.stateMachine.handle(.release(toCompleted: completed))
        settle(toCompleted: completed)
    }

    // MARK: - Settle (§3)

    private func settle(toCompleted completed: Bool) {
        guard var active = transition.activeTransition, !active.didCleanUp else { return }
        let context = active.context
        let transitionAnimator = active.transitionAnimator
        let portal = active.animationContext.portal

        // 1. Tell UIKit which way we're going — the continuation's start point.
        if completed {
            context.finishInteractiveTransition()
        } else {
            context.cancelInteractiveTransition()
        }

        // 2. Reverse the transition animator first (cancel only).
        if !completed { transitionAnimator.isReversed = true }

        // 3. Continue the paused transition animator to its end.
        let fraction = transitionAnimator.fractionComplete
        let durationFactor = completed ? (1 - fraction) : fraction
        transitionAnimator.continueAnimation(withTimingParameters: nil, durationFactor: max(durationFactor, 0.0001))

        // 4. Re-resolve the source at settle time (complete only — the cell may have moved during
        //    the scrub); keep the existing rect on failure.
        let geometry = active.animationContext.geometry
        let targetRect: CGRect
        if completed {
            targetRect = reresolveSourceRect(active: active)
                ?? geometry?.sourceRect
                ?? active.animationContext.finalFrame
        } else {
            targetRect = active.animationContext.finalFrame
        }

        // 5. Fresh geometry spring from the portal's current state → target, seeded with the
        //    release velocity, plus the matching corner morph.
        let currentRect = portal.layer.presentation()?.frame ?? portal.frame
        // Normalise against the remaining *distance magnitude* per axis (the target can be above or
        // below the portal, so a signed delta would mis-scale via the helper's `max(_, 1)` floor);
        // the velocity's own sign carries the direction into the spring.
        let remaining = CGPoint(
            x: abs(targetRect.midX - currentRect.midX),
            y: abs(targetRect.midY - currentRect.midY)
        )
        let initialVelocity = SpringConverter.normalizedVelocity(lastGestureVelocity, remainingDistance: remaining)

        let geometryAnimators = (active.strategy as? ZoomAnimator)?.makeGeometryAnimators(
            using: active.animationContext,
            targetPortalRect: targetRect,
            initialVelocity: initialVelocity
        ) ?? []
        if let geometry {
            let targetCorner = completed ? geometry.sourceCornerRadius : geometry.finalCornerRadius
            geometryAnimators.first?.addAnimations { portal.portalCornerRadius = targetCorner }
        }

        // 6. Barrier (3b, generation-guarded): fresh generation, count, completions, then start.
        active.barrierGeneration += 1
        active.geometryAnimators = geometryAnimators
        active.pendingAnimatorCount = 1 + geometryAnimators.count
        active.settleCompleted = completed
        transition.activeTransition = active

        let generation = active.barrierGeneration
        addBarrierCompletion(to: transitionAnimator, generation: generation)
        geometryAnimators.forEach { addBarrierCompletion(to: $0, generation: generation) }
        geometryAnimators.forEach { $0.startAnimation() }
    }

    // MARK: - Grab (freeze-and-rebuild, §4)

    private func performGrab(_ gesture: UIPanGestureRecognizer) {
        guard var active = transition.activeTransition, !active.didCleanUp else { return }
        let effects = transition.stateMachine.handle(.grab)
        guard effects.contains(.freezeGeometryAndPauseTransition) else { return }

        let portal = active.animationContext.portal
        let strategy = active.strategy
        let animationContext = active.animationContext
        let springsToFreeze = active.geometryAnimators
        let transitionAnimator = active.transitionAnimator

        // Publish the bumped generation and cleared count *before* firing any `finishAnimation`
        // below: those completions run synchronously and read the stored generation, so this is what
        // makes them no-op against the barrier instead of prematurely tripping it (§4/§8).
        active.barrierGeneration += 1
        active.pendingAnimatorCount = 0
        active.geometryAnimators = []
        transition.activeTransition = active

        // 1. Freeze the geometry springs: stamp the presentation values into the model, then drop.
        for spring in springsToFreeze {
            switch spring.state {
            case .active:
                spring.stopAnimation(false)
                spring.finishAnimation(at: .current)
            case .stopped:
                spring.finishAnimation(at: .current)
            default:
                break
            }
        }

        // 2. Transition animator. `fractionComplete` is the global progress the visual sits at.
        baseProgress = min(max(transitionAnimator.fractionComplete, 0), 1)

        if transitionAnimator.isReversed {
            // A cancel settle runs it backwards — never scrub a reversed animator (§4). Stop it,
            // stamp the current values, and rebuild a fresh paused-at-0 animator mapping
            // [current → dismiss-complete]; subsequent scrubs remap onto it via `baseProgress`.
            if transitionAnimator.state == .active {
                transitionAnimator.stopAnimation(false)
                transitionAnimator.finishAnimation(at: .current)
            }
            if let zoomAnimator = strategy as? ZoomAnimator {
                let fresh = zoomAnimator.makeTransitionAnimator(using: animationContext)
                fresh.pauseAnimation()
                var republished = transition.activeTransition ?? active
                republished.transitionAnimator = fresh
                transition.activeTransition = republished
            }
            transitionBaseFraction = baseProgress
        } else {
            // Forward run/pause is scrub-safe: pause and keep scrubbing the same animator.
            if transitionAnimator.state == .active {
                transitionAnimator.pauseAnimation()
            }
            transitionBaseFraction = 0
        }

        // 3. Re-seed the follow model from the portal's live position, then make subsequent samples
        //    relative to the grab point.
        let center = portal.layer.presentation()?.position ?? portal.center
        seedFollowModel(initialCenter: center)
        gesture.setTranslation(.zero, in: gesture.view)
    }

    // MARK: - Completion barrier (interactive)

    private func addBarrierCompletion(to animator: UIViewPropertyAnimator, generation: Int) {
        animator.addCompletion { [weak self] _ in
            self?.barrierDidFinishOne(generation: generation)
        }
    }

    private func barrierDidFinishOne(generation: Int) {
        guard var active = transition.activeTransition, !active.didCleanUp,
              active.barrierGeneration == generation else { return }
        active.pendingAnimatorCount -= 1
        transition.activeTransition = active
        if active.pendingAnimatorCount <= 0 {
            interactiveComplete(active.settleCompleted)
        }
    }

    /// The interactive analogue of `TransitionDriver.completionBarrierFired`: order is cleanup →
    /// `completeTransition` → `reportDidEnd` (the same order as the non-interactive barrier, which
    /// is safe against UIKit's `animationEnded` re-entry because cleanup drops the active transition
    /// first). `cleanup` performs the cancel-recovery re-stamp (identity transform + finalFrame) and
    /// unhides the source via `strategy.finish`, and re-enables the scroll view via the token.
    private func interactiveComplete(_ completed: Bool) {
        guard let active = transition.activeTransition, !active.didCleanUp else { return }
        let context = active.context
        let contextInfo = active.contextInfo
        let fallbackReason = active.fallbackReason

        transition.stateMachine.handle(.allAnimatorsFinished)
        animationDriver?.cleanup(finished: completed)
        context.completeTransition(completed)

        // iOS 15 ghosting workaround (§7.8): after a *cancelled* interactive pop, force the nav bar to
        // re-lay out so a large-title bar doesn't leave a ghost of the aborted transition.
        if operation == .pop, !completed {
            transition.attachedViewController?.navigationController?.navigationBar.setNeedsLayout()
        }

        transition.reportDidEnd(
            contextInfo,
            result: ZoomTransition.Result(isCompleted: completed, wasInteractive: true, fallbackReason: fallbackReason)
        )
    }

    // MARK: - Helpers

    private func triggerDismissal() {
        guard let viewController = transition.attachedViewController else { return }
        switch operation {
        case .pop:
            viewController.navigationController?.popViewController(animated: true)
        default:
            viewController.dismiss(animated: true)
        }
    }

    private func seedFollowModel(initialCenter: CGPoint? = nil) {
        guard let active = transition.activeTransition else { return }
        let container = active.animationContext.containerView
        let center = initialCenter ?? active.animationContext.portal.center
        follow = FollowModel(containerSize: container.bounds.size, initialCenter: center)
        if initialCenter == nil {
            // Fresh start (not a re-grab): reset the progress bases.
            baseProgress = 0
            transitionBaseFraction = 0
        }
    }

    private func reresolveSourceRect(active: ActiveTransition) -> CGRect? {
        let result = SourceViewResolver.resolve(
            provider: transition.sourceViewProvider,
            context: active.contextInfo,
            zoomedView: active.animationContext.zoomedView,
            containerView: active.animationContext.containerView
        )
        if case .success(let source) = result { return source.rectInContainer }
        return nil
    }

    private func lockTopScrollViewIfNeeded() {
        guard let active = transition.activeTransition,
              let scrollView = topScrollView(in: active.animationContext.zoomedView),
              scrollView.isScrollEnabled else { return }
        active.animationContext.restorationToken.recordScrollLock(of: scrollView)
        scrollView.isScrollEnabled = false
    }

    /// Breadth-first search for the top-most `UIScrollView` in a subtree.
    private func topScrollView(in root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        var index = 0
        while index < queue.count {
            let view = queue[index]
            index += 1
            if let scrollView = view as? UIScrollView { return scrollView }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func isScrolledToTop(_ scrollView: UIScrollView) -> Bool {
        scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ZoomInteractionDriver: UIGestureRecognizerDelegate {

    /// Begins only for a downward-dominant drag while any top-most scroll view is at its top (or
    /// there is none), and only when the state machine can accept a fresh start (idle + a
    /// gesture-initiated driver) or a grab (animating/settling). See §2.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard transition.configuration.interactiveDismissal == .pan else { return false }
        // VoiceOver suppresses interactive dismissal entirely (§9) — the swipe must not begin.
        guard !transition.suppressesInteractionForAccessibility else { return false }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }

        let translation = pan.translation(in: view)
        guard translation.y > 0, abs(translation.y) > abs(translation.x) else { return false }

        if let scrollView = topScrollView(in: view), !isScrolledToTop(scrollView) { return false }

        switch transition.stateMachine.state {
        case .idle:
            // A fresh gesture-initiated dismiss. Not gated on `wantsInteractiveStart` (see
            // `handlePanBegan`): the flag is only vended *during* the dismissal this begin triggers,
            // so requiring it here would deadlock the built-in pan dismiss. The downward-from-top,
            // scroll-at-top, and VoiceOver checks above already established legitimate intent.
            return true
        case .animating, .settling: return true
        case .interactive: return false
        }
    }

    /// Recognises simultaneously with the destination scroll view's own pan so a from-top drag can
    /// hand over to the dismissal without the scroll view swallowing it.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer
    }
}
