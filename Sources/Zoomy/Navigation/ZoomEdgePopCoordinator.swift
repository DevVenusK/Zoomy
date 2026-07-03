import UIKit

/// Wires the system left-edge pop gesture to Zoomy's interactive zoom pop **without breaking the
/// stock slide pop on non-zoom screens** (TECH_SPEC §7.4 / brief §1–§2).
///
/// ### Why explicit wiring is needed
/// Vending a custom pop animator does **not** make the system `interactivePopGestureRecognizer`
/// drive that custom transition — the system recognizer's built-in target runs the stock slide, and
/// letting it fire alongside a custom pop double-pops or corrupts the nav stack. So on a zoom screen
/// we drive the pop with our **own** `UIScreenEdgePanGestureRecognizer` (installed on the nav view)
/// and make the system recognizer *refuse to begin* via this arbitrator; on every non-zoom screen
/// we leave the system recognizer alone (delegating its `shouldBegin` back to the delegate it had),
/// so the stock pop is byte-for-byte preserved.
///
/// ### What it does not do
/// It never removes the system recognizer's built-in target (that would break stock pop on other
/// screens) and never swizzles or KVO-observes. Suppression is expressed only through
/// `gestureRecognizerShouldBegin == false` on a zoom screen. The edge pan reuses M6's
/// `ZoomInteractionDriver` settle/grab/barrier logic verbatim — this object only decides *when* the
/// edge pan may begin and routes its updates into the driver.
///
/// Retained strongly by the ``ZoomNavigationDelegate`` proxy (gesture recognizers hold their targets
/// weakly, so something must own this); holds the navigation controller `weak`.
@MainActor
final class ZoomEdgePopCoordinator: NSObject {

    /// The navigation controller this coordinator arbitrates. Weak — the nav retains the proxy that
    /// retains this coordinator.
    weak var navigationController: UINavigationController?

    /// Our own left-edge pan, installed on the nav view by `installIfNeeded`. It — not the system
    /// recognizer — drives the interactive zoom pop on a zoom screen.
    private(set) var edgePanGesture: UIScreenEdgePanGestureRecognizer?

    /// The delegate the system `interactivePopGestureRecognizer` had before we became its delegate,
    /// preserved so a non-zoom screen keeps its exact stock pop behaviour (we forward `shouldBegin`
    /// and the other delegate callbacks back to it). Weak — UIKit owns it (typically the nav
    /// controller's own private interactive-transition object).
    private(set) weak var originalPopDelegate: (any UIGestureRecognizerDelegate)?

    /// The driver an in-flight edge swipe is currently feeding, captured at `.began`. Held across the
    /// gesture because `popViewController` updates `nav.topViewController` to the predecessor, so the
    /// zoom transition can no longer be re-resolved from the top VC once the pop has been triggered.
    private weak var activeEdgeDriver: ZoomInteractionDriver?

    private var didInstall = false

    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
        super.init()
    }

    // MARK: - Install

    /// Idempotent: installs our left-edge pan on the nav view and makes this object the delegate of
    /// the system `interactivePopGestureRecognizer` (preserving its original delegate). Called from
    /// the proxy's `didShow` once a zoom screen appears.
    func installIfNeeded() {
        guard let nav = navigationController, !didInstall else { return }
        didInstall = true

        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        edge.edges = .left
        edge.maximumNumberOfTouches = 1
        edge.delegate = self
        nav.view.addGestureRecognizer(edge)
        edgePanGesture = edge

        // Arbitrate — never disable — the system recognizer: keep its built-in target so other
        // screens' stock pop still runs, but gate its `begin` through us.
        if let system = nav.interactivePopGestureRecognizer {
            originalPopDelegate = system.delegate
            system.delegate = self
        }
    }

    // MARK: - Edge pan handling

    /// Routes the edge swipe into M6's `ZoomInteractionDriver` (declared over `UIPanGestureRecognizer`
    /// so tests can drive it with a mock — `UIScreenEdgePanGestureRecognizer` is a subclass):
    /// - `.began` on a poppable zoom screen: mark the driver gesture-initiated, register the gesture
    ///   so `isGestureActive` sees it, then hand `.began` to `handlePan` — which triggers
    ///   `popViewController`, so the proxy vends the pop driver and pairs the interactive driver.
    /// - `.changed` / end states: forwarded to the driver captured at `.began` (the top VC has since
    ///   become the predecessor, so it can't be re-resolved from the stack).
    @objc func handleEdgePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let nav = navigationController,
                  let transition = poppableZoom(in: nav),
                  !transition.suppressesInteractionForAccessibility,
                  transition.stateMachine.state == .idle else { return }
            let driver = transition.makeInteractionDriver(operation: .pop)
            driver.wantsInteractiveStart = true
            driver.registerExternalDrivingGesture(gesture)
            activeEdgeDriver = driver
            driver.handlePan(gesture)
        case .changed:
            activeEdgeDriver?.handlePan(gesture)
        case .ended, .cancelled, .failed:
            activeEdgeDriver?.handlePan(gesture)
            activeEdgeDriver = nil
        default:
            break
        }
    }

    // MARK: - Zoom-screen predicate

    /// The zoom transition on the top VC that our edge pan may interactively pop, or `nil` on any
    /// screen where the stock pop must be preserved: it requires more than one VC on the stack, a
    /// `.pan` zoom transition on the top VC, and that the zoom was pushed as an adjacent step
    /// (`pushPredecessor != nil`, the same gate the non-interactive pop vend uses). State is *not*
    /// checked here — callers add the `.idle` requirement where a *fresh* begin needs it.
    private func poppableZoom(in nav: UINavigationController) -> ZoomTransition? {
        guard nav.viewControllers.count > 1,
              let top = nav.topViewController,
              let transition = top.zoomTransition,
              transition.configuration.interactiveDismissal == .pan,
              transition.pushPredecessor != nil else { return nil }
        return transition
    }
}

// MARK: - UIGestureRecognizerDelegate (the arbitrator)

extension ZoomEdgePopCoordinator: UIGestureRecognizerDelegate {

    /// The heart of the arbitration:
    /// - **our edge pan** begins only on a poppable zoom screen whose transition is idle;
    /// - the **system recognizer** is refused (returns `false`) on a zoom screen — our edge pan owns
    ///   the pop there — and otherwise delegates to the recognizer's original delegate (so stock pop
    ///   is preserved exactly; `nil` original → `true`, UIKit's default).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = navigationController else { return false }

        if gestureRecognizer === edgePanGesture {
            // Never start a second pop while any nav transition is in flight (guards the chained-zoom
            // case where the revealed predecessor is itself an idle zoom): the brief's "avoid double
            // pop" intent. The in-progress gesture is unaffected — `shouldBegin` is not re-queried
            // once it has begun.
            guard nav.transitionCoordinator == nil else { return false }
            guard let zoom = poppableZoom(in: nav),
                  !zoom.suppressesInteractionForAccessibility else { return false }
            return zoom.stateMachine.state == .idle
        }

        // System interactivePopGestureRecognizer.
        if poppableZoom(in: nav) != nil {
            return false
        }
        return originalPopDelegate?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === edgePanGesture { return false }
        return originalPopDelegate?.gestureRecognizer?(
            gestureRecognizer, shouldRecognizeSimultaneouslyWith: otherGestureRecognizer
        ) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === edgePanGesture { return false }
        return originalPopDelegate?.gestureRecognizer?(
            gestureRecognizer, shouldRequireFailureOf: otherGestureRecognizer
        ) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === edgePanGesture { return false }
        return originalPopDelegate?.gestureRecognizer?(
            gestureRecognizer, shouldBeRequiredToFailBy: otherGestureRecognizer
        ) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        if gestureRecognizer === edgePanGesture { return true }
        return originalPopDelegate?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
    }
}
