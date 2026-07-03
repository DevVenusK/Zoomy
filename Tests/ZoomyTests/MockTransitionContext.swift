import UIKit
@testable import Zoomy

/// A minimal `UIViewControllerContextTransitioning` for driving a `TransitionDriver` directly in
/// a unit test (no real `present`/`dismiss` lifecycle), recording the completion/interaction
/// callbacks the driver makes (brief §9).
@MainActor
final class MockTransitionContext: NSObject, UIViewControllerContextTransitioning {

    let containerView: UIView
    private let fromViewController: UIViewController
    private let toViewController: UIViewController
    private let fromView: UIView
    private let toView: UIView

    // Recording.
    private(set) var completeTransitionCallCount = 0
    private(set) var completeTransitionFlags: [Bool] = []
    private(set) var updateInteractiveCallCount = 0
    private(set) var lastUpdateInteractivePercent: CGFloat?
    private(set) var finishInteractiveCallCount = 0
    private(set) var cancelInteractiveCallCount = 0
    private(set) var pauseInteractiveCallCount = 0
    /// Ordered log of the interactive/completion callbacks, for asserting call *order* (§8): e.g.
    /// `["update", "finish", "complete(true)"]`.
    private(set) var eventLog: [String] = []

    /// Toggleable so a test can present an interactive context (§8). Defaults to `false`.
    var isInteractiveOverride = false

    init(
        containerView: UIView,
        fromViewController: UIViewController,
        toViewController: UIViewController,
        fromView: UIView,
        toView: UIView
    ) {
        self.containerView = containerView
        self.fromViewController = fromViewController
        self.toViewController = toViewController
        self.fromView = fromView
        self.toView = toView
        super.init()
    }

    var isAnimated: Bool { true }
    var isInteractive: Bool { isInteractiveOverride }
    var transitionWasCancelled: Bool { false }
    var presentationStyle: UIModalPresentationStyle { .custom }
    var targetTransform: CGAffineTransform { .identity }

    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? {
        switch key {
        case .from: return fromViewController
        case .to: return toViewController
        default: return nil
        }
    }

    func view(forKey key: UITransitionContextViewKey) -> UIView? {
        switch key {
        case .from: return fromView
        case .to: return toView
        default: return nil
        }
    }

    func initialFrame(for vc: UIViewController) -> CGRect { containerView.bounds }
    func finalFrame(for vc: UIViewController) -> CGRect { containerView.bounds }

    func completeTransition(_ didComplete: Bool) {
        completeTransitionCallCount += 1
        completeTransitionFlags.append(didComplete)
        eventLog.append("complete(\(didComplete))")
    }

    func updateInteractiveTransition(_ percentComplete: CGFloat) {
        updateInteractiveCallCount += 1
        lastUpdateInteractivePercent = percentComplete
        eventLog.append("update")
    }

    func finishInteractiveTransition() {
        finishInteractiveCallCount += 1
        eventLog.append("finish")
    }

    func cancelInteractiveTransition() {
        cancelInteractiveCallCount += 1
        eventLog.append("cancel")
    }

    func pauseInteractiveTransition() {
        pauseInteractiveCallCount += 1
        eventLog.append("pause")
    }
}
