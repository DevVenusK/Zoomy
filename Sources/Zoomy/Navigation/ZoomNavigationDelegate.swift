import UIKit
import os.log

/// A `UINavigationControllerDelegate` proxy that adds Zoomy's push/pop zoom on top of whatever
/// delegate the app already uses. Install it with `UINavigationController.enableZoomTransitions()`,
/// which wraps the current delegate as this proxy's ``downstream``.
///
/// The proxy implements four delegate methods itself — `animationControllerFor` (the push/pop
/// vend rules, §3), `interactionControllerFor`, and `willShow`/`didShow` (internal hooks that then
/// hand off to `downstream`) — and transparently forwards every *other* delegate message to
/// `downstream` via `responds(to:)` + `forwardingTarget(for:)`.
///
/// ### Message-forwarding limitation (documented, not a bug)
/// A fully belt-and-braces "dead downstream" safety net would use `methodSignature(for:)` +
/// `forwardInvocation(_:)` to swallow a stale selector after `downstream` deallocates. `NSInvocation`
/// (and therefore `forwardInvocation(_:)`) is **not available in Swift**, so that net cannot be
/// expressed here. The defence Zoomy uses instead is:
/// 1. `downstream` is `weak`; once it dies, `responds(to:)` reports `false` for its selectors, so
///    freshly-queried capabilities are correct.
/// 2. Setting ``downstream`` re-assigns `navigationController.delegate = self`, which forces UIKit
///    to drop its cached capability flags and re-query `responds(to:)`.
///
/// The only residual window is a downstream that deallocates *without* going through the
/// ``downstream`` setter while UIKit still holds stale capability flags. **If you swap or drop the
/// object behind `downstream`, re-assign it through this proxy** (or call `enableZoomTransitions()`
/// again) so the cache is invalidated. Zoomy never `swizzle`s or KVO-observes to detect this.
@MainActor
public final class ZoomNavigationDelegate: NSObject, UINavigationControllerDelegate {

    /// The app's own navigation delegate, wrapped so it keeps receiving every message the proxy
    /// doesn't handle itself. Held `weak` — mirror UIKit's own `delegate` ownership. Stored in a
    /// `nonisolated(unsafe)` box so the `nonisolated` `responds(to:)` / `forwardingTarget(for:)`
    /// overrides (which the ObjC runtime may call) can read it; in practice all access is on main.
    private nonisolated(unsafe) weak var _downstream: (any UINavigationControllerDelegate)?

    /// The app's own navigation delegate. Assigning it walks the forwarding chain for a cycle
    /// (`=== self`) and, if the proxy is already attached to a navigation controller, re-assigns
    /// `navigationController.delegate = self` to invalidate UIKit's cached capability flags.
    public var downstream: (any UINavigationControllerDelegate)? {
        get { _downstream }
        set {
            if let newValue, chainContainsSelf(startingFrom: newValue) {
                ZoomyAssert.fail("ZoomNavigationDelegate detected a delegate-forwarding cycle; downstream not set")
                return
            }
            _downstream = newValue
            invalidateDelegateCapabilityCache()
        }
    }

    /// The navigation controller this proxy is installed on, set by `enableZoomTransitions()`.
    /// Held `weak` — the navigation controller retains the proxy via an associated object.
    weak var navigationController: UINavigationController?

    /// The edge-swipe pop coordinator (M5), lazily created the first time a zoom screen appears. It
    /// owns our left-edge pan on the nav view and arbitrates the system `interactivePopGestureRecognizer`
    /// so a zoom screen's pop is driven by our edge pan while non-zoom screens keep the stock pop.
    /// Retained here strongly (gesture recognizers hold their targets weakly), released with the proxy
    /// (i.e. with the navigation controller). Never created on a nav that never shows a zoom screen.
    private(set) var edgePopCoordinator: ZoomEdgePopCoordinator?

    public init(forwardingTo downstream: (any UINavigationControllerDelegate)? = nil) {
        super.init()
        self.downstream = downstream
    }

    // MARK: - Directly implemented delegate methods

    /// The push/pop vend rules (§3). Zoom is vended only for a *single adjacent step*:
    /// - `.push`: the destination has an idle `zoomTransition` (records `pushPredecessor = fromVC`).
    /// - `.pop`: the departing VC has an idle `zoomTransition` whose recorded `pushPredecessor` is
    ///   exactly `toVC` (i.e. we're returning to the screen we were pushed from).
    ///
    /// Everything else (a multi-level pop, `setViewControllers`, a mismatched predecessor, a
    /// non-idle state machine) falls through to `downstream` — or `nil`, the system default. No
    /// `willBegin`/`didEnd` is reported for those, since no zoom or fallback actually runs.
    public func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        switch operation {
        case .push:
            if let transition = toVC.zoomTransition, transition.stateMachine.state == .idle {
                transition.pushPredecessor = fromVC
                // Reduce Motion / VoiceOver (§9): the same driver runs a cross-dissolve instead.
                return TransitionDriver(
                    transition: transition, phase: .appearing, operation: .push,
                    forcedFallbackReason: transition.accessibilityFallbackReason
                )
            }
            return downstream?.navigationController?(
                navigationController, animationControllerFor: operation, from: fromVC, to: toVC
            )

        case .pop:
            if let transition = fromVC.zoomTransition {
                if toVC === transition.pushPredecessor, transition.stateMachine.state == .idle {
                    return TransitionDriver(
                        transition: transition, phase: .disappearing, operation: .pop,
                        forcedFallbackReason: transition.accessibilityFallbackReason
                    )
                }
                // A zoom is attached but this isn't the single adjacent pop it was pushed as
                // (multi-level pop, or a non-idle/reentrant state). The system default runs.
                logUnsupported("pop (non-adjacent or non-idle)")
            }
            return downstream?.navigationController?(
                navigationController, animationControllerFor: operation, from: fromVC, to: toVC
            )

        case .none:
            logUnsupported("none (setViewControllers)")
            return downstream?.navigationController?(
                navigationController, animationControllerFor: operation, from: fromVC, to: toVC
            )

        @unknown default:
            return downstream?.navigationController?(
                navigationController, animationControllerFor: operation, from: fromVC, to: toVC
            )
        }
    }

    /// Pairs our interactive pop driver with the pop `TransitionDriver` we vended, but **only when a
    /// pan is actually driving the pop** (§6). A programmatic/back-button pop leaves the recognizer
    /// idle, so the non-interactive driver runs. Any animation controller we didn't vend is
    /// forwarded downstream.
    public func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        if let driver = animationController as? TransitionDriver {
            if driver.operation == .pop,
               driver.transition.configuration.interactiveDismissal == .pan,
               !driver.transition.suppressesInteractionForAccessibility,
               let interactionDriver = driver.transition.interactionDriver,
               interactionDriver.isGestureActive {
                interactionDriver.wantsInteractiveStart = true
                interactionDriver.animationDriver = driver
                return interactionDriver
            }
            // Our own non-interactive pop/push driver — no interaction controller to pair.
            return nil
        }
        return downstream?.navigationController?(navigationController, interactionControllerFor: animationController)
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        downstream?.navigationController?(navigationController, willShow: viewController, animated: animated)
    }

    /// Installs the interactive pop pan on a destination that was pushed as a zoom (M6). A pushed
    /// zoom records a `pushPredecessor`, so its presence marks the adjacent detail that can be
    /// popped interactively. The recognizer's `gestureRecognizerShouldBegin` still gates on a
    /// downward-from-top drag, so it coexists with the screen's own scrolling.
    private func installInteractivePopIfNeeded(on viewController: UIViewController) {
        guard let transition = viewController.zoomTransition,
              transition.configuration.interactiveDismissal == .pan,
              transition.pushPredecessor != nil else { return }
        let driver = transition.makeInteractionDriver(operation: .pop)
        driver.installGesture(on: viewController.view)
    }

    /// Installs the edge-swipe pop coordinator (M5) the first time a zoom screen appears — it owns
    /// our left-edge pan on the nav view and arbitrates the system `interactivePopGestureRecognizer`.
    /// Gated on the shown VC carrying a `.pan` zoom so a nav that never presents a zoom screen keeps
    /// its stock edge pop entirely untouched (the coordinator is never created). `installIfNeeded`
    /// itself is idempotent, so re-entry across further `didShow`s is a no-op.
    private func installEdgeSwipePopIfNeeded(
        on navigationController: UINavigationController,
        topViewController: UIViewController
    ) {
        guard let transition = topViewController.zoomTransition,
              transition.configuration.interactiveDismissal == .pan else { return }
        let coordinator = edgePopCoordinator ?? {
            let created = ZoomEdgePopCoordinator(navigationController: navigationController)
            edgePopCoordinator = created
            return created
        }()
        coordinator.installIfNeeded()
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        // `pushPredecessor` is intentionally not cleared here: it is `weak` (auto-nils with the
        // popped VC) and is always overwritten at the next push vend *before* any pop reads it, so
        // it can never be read stale. (§3 lists explicit cleanup as optional.)
        installEdgeSwipePopIfNeeded(on: navigationController, topViewController: viewController)
        installInteractivePopIfNeeded(on: viewController)
        downstream?.navigationController?(navigationController, didShow: viewController, animated: animated)
    }

    // MARK: - Message forwarding

    /// `true` for the proxy's own selectors, otherwise whatever the live `downstream` reports. When
    /// `downstream` is `nil` (never set, or deallocated) this correctly reports `false` for
    /// downstream-only selectors, which is the first line of defence against stale calls.
    nonisolated public override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return _downstream?.responds(to: aSelector) ?? false
    }

    /// Routes any selector the proxy doesn't implement itself to the live `downstream` (fast ObjC
    /// forwarding — works for object, primitive, and struct return types alike).
    nonisolated public override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let downstream = _downstream, downstream.responds(to: aSelector) {
            return downstream
        }
        return super.forwardingTarget(for: aSelector)
    }

    // MARK: - Helpers

    /// Walks the forwarding chain from `candidate` (following nested `ZoomNavigationDelegate`
    /// downstreams) looking for `self`, so a cycle is caught before it can loop `responds(to:)`.
    private func chainContainsSelf(startingFrom candidate: any UINavigationControllerDelegate) -> Bool {
        var current: (any UINavigationControllerDelegate)? = candidate
        while let node = current {
            if node === self { return true }
            current = (node as? ZoomNavigationDelegate)?._downstream
        }
        return false
    }

    /// Forces UIKit to drop cached delegate-capability flags by re-assigning the delegate, so a
    /// changed `downstream` (which may respond to a different set of selectors) is re-queried.
    private func invalidateDelegateCapabilityCache() {
        guard let nav = navigationController, nav.delegate === self else { return }
        nav.delegate = nil
        nav.delegate = self
    }

    private func logUnsupported(_ operation: String) {
        #if DEBUG
        os_log(
            "ZoomNavigationDelegate: unsupported navigation operation %{public}@ — using the system default",
            log: .zoomy,
            type: .debug,
            operation
        )
        #endif
    }
}
