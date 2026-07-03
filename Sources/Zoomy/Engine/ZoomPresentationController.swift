import UIKit

/// The `UIPresentationController` for a modal zoom (`docs/TECH_SPEC.md` §5.8 / §7). It owns the
/// dimming view (whose alpha the transition animator drives), keeps the presenter's view alive
/// beneath the destination, and pins accessibility/status-bar behaviour. It never stamps the
/// presented frame while a transition is running — that would fight the portal geometry.
final class ZoomPresentationController: UIPresentationController {

    unowned let transition: ZoomTransition

    /// Created from `configuration.dimmingColor` (nil → no dimming). Inserted at the bottom of
    /// the container; its alpha is animated by the transition animator, not here.
    let dimmingView: UIView?

    init(
        presentedViewController: UIViewController,
        presenting presentingViewController: UIViewController?,
        transition: ZoomTransition
    ) {
        self.transition = transition
        if let color = transition.configuration.dimmingColor {
            let view = UIView()
            view.backgroundColor = color
            view.alpha = 0
            self.dimmingView = view
        } else {
            self.dimmingView = nil
        }
        super.init(presentedViewController: presentedViewController, presenting: presentingViewController)
    }

    override var shouldRemovePresentersView: Bool { false }

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()

        if let containerView, let dimmingView {
            dimmingView.frame = containerView.bounds
            dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            containerView.insertSubview(dimmingView, at: 0)
        }

        presentedViewController.modalPresentationCapturesStatusBarAppearance = true

        if transition.configuration.resignsFirstResponders {
            presentingViewController.view.endEditing(true)
        }

        containerView?.accessibilityViewIsModal = true
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        // While a zoom is running the portal owns the presented view's geometry — stamping the
        // frame here would snap it out of the flight.
        guard transition.activeTransition == nil else { return }
        if let containerView {
            presentedView?.frame = containerView.bounds
        }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        if completed {
            dimmingView?.removeFromSuperview()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        presentedViewController.dismiss(animated: true)
        return true
    }

    // TODO(M7): override `viewWillTransition(to:with:)` to `forceFinish(.sizeChange)` an
    // in-flight transition on rotation.
}
