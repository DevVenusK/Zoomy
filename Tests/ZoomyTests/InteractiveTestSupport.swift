import UIKit
@testable import Zoomy

/// A `UIPanGestureRecognizer` whose `state`/`translation`/`velocity`/`view` are directly settable,
/// so `ZoomInteractionDriver.handlePan` and its gesture-delegate logic can be driven deterministically
/// from a unit test (real recognizers can't have these forced).
final class MockPanGestureRecognizer: UIPanGestureRecognizer {
    var mockState: UIGestureRecognizer.State = .possible
    var mockTranslation: CGPoint = .zero
    var mockVelocity: CGPoint = .zero
    var mockView: UIView?

    override var state: UIGestureRecognizer.State {
        get { mockState }
        set { mockState = newValue }
    }

    override var view: UIView? { mockView }

    override func translation(in view: UIView?) -> CGPoint { mockTranslation }
    override func velocity(in view: UIView?) -> CGPoint { mockVelocity }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { mockTranslation = translation }
}

/// Records `dismiss(animated:)` without touching UIKit's real (unavailable in a unit test)
/// presentation machinery — lets a test observe that a gesture-initiated begin triggered the
/// dismissal (C1 gate).
final class DismissSpyViewController: UIViewController {
    private(set) var dismissCallCount = 0
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        dismissCallCount += 1
        completion?()
    }
}

/// The staged pieces of an interactive dismiss driven through a `MockTransitionContext`, mirroring
/// `ModalCallOrderTests`'s scene but wired for the interactive path (§8).
@MainActor
struct InteractiveScene {
    let window: UIWindow
    let container: UIView
    let presenter: UIViewController
    let detail: UIViewController
    let source: UIView
    let transition: ZoomTransition
    let animationDriver: TransitionDriver
    let driver: ZoomInteractionDriver
    let context: MockTransitionContext

    /// Runs `startInteractiveTransition` (what UIKit would call after a gesture-initiated dismiss),
    /// staging the transition and seeding the follow model.
    func start() {
        driver.startInteractiveTransition(context)
    }

    func pan(_ state: UIGestureRecognizer.State, translation: CGPoint, velocity: CGPoint = .zero) {
        let gesture = MockPanGestureRecognizer()
        gesture.mockView = detail.view
        gesture.mockState = state
        gesture.mockTranslation = translation
        gesture.mockVelocity = velocity
        driver.handlePan(gesture)
    }
}

/// - Parameters:
///   - detail: injectable destination VC (e.g. a `DismissSpyViewController`); a plain VC by default.
///   - presetInteractiveStart: whether to pre-set `wantsInteractiveStart = true` (mirrors the
///     post-vend state that the settle/grab tests exercise). Pass `false` to reproduce the true
///     pre-vend state and drive the `shouldBegin`/`began` gate directly (C1 gate).
@MainActor
func makeInteractiveDismissScene(
    resolvesSource: Bool = true,
    delegate: ZoomTransitionDelegate? = nil,
    detail: UIViewController? = nil,
    presetInteractiveStart: Bool = true
) -> InteractiveScene {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

    let presenter = UIViewController()
    presenter.view.frame = window.bounds
    presenter.view.backgroundColor = .white
    let source = UIView(frame: CGRect(x: 80, y: 320, width: 160, height: 160))
    source.backgroundColor = .systemRed
    source.layer.cornerRadius = 12
    presenter.view.addSubview(source)
    window.rootViewController = presenter
    window.isHidden = false

    let container = UIView(frame: window.bounds)
    container.backgroundColor = .clear
    window.addSubview(container)

    let detail = detail ?? UIViewController()
    detail.view.backgroundColor = .systemBlue

    let transition = ZoomTransition { _ -> UIView? in resolvesSource ? source : nil }
    transition.delegate = delegate
    detail.zoomTransition = transition

    // The destination is already "presented": its view sits in the container.
    detail.view.frame = container.bounds
    container.addSubview(detail.view)
    container.layoutIfNeeded()

    let context = MockTransitionContext(
        containerView: container,
        fromViewController: detail,
        toViewController: presenter,
        fromView: detail.view,
        toView: presenter.view
    )
    context.isInteractiveOverride = true

    let animationDriver = TransitionDriver(transition: transition, phase: .disappearing, operation: .dismiss)
    let driver = transition.makeInteractionDriver(operation: .dismiss)
    driver.animationDriver = animationDriver
    driver.wantsInteractiveStart = presetInteractiveStart

    return InteractiveScene(
        window: window,
        container: container,
        presenter: presenter,
        detail: detail,
        source: source,
        transition: transition,
        animationDriver: animationDriver,
        driver: driver,
        context: context
    )
}

/// The staged pieces of an interactive **pop** (navigation) driven through a `MockTransitionContext`,
/// used to exercise the push/pop dimming path (nav backdrop) the modal scene doesn't have.
@MainActor
struct InteractivePopScene {
    let window: UIWindow
    let container: UIView
    let predecessor: UIViewController
    let detail: UIViewController
    let source: UIView
    let transition: ZoomTransition
    let animationDriver: TransitionDriver
    let driver: ZoomInteractionDriver
    let context: MockTransitionContext

    func start() { driver.startInteractiveTransition(context) }
}

@MainActor
func makeInteractivePopScene(
    resolvesSource: Bool = true,
    delegate: ZoomTransitionDelegate? = nil
) -> InteractivePopScene {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

    let predecessor = UIViewController()
    predecessor.view.frame = window.bounds
    predecessor.view.backgroundColor = .white
    let source = UIView(frame: CGRect(x: 80, y: 320, width: 160, height: 160))
    source.backgroundColor = .systemRed
    predecessor.view.addSubview(source)
    window.rootViewController = predecessor
    window.isHidden = false

    let container = UIView(frame: window.bounds)
    container.backgroundColor = .clear
    window.addSubview(container)

    let detail = UIViewController()
    detail.view.backgroundColor = .systemBlue
    let transition = ZoomTransition { _ -> UIView? in resolvesSource ? source : nil }
    transition.delegate = delegate
    detail.zoomTransition = transition
    transition.pushPredecessor = predecessor

    detail.view.frame = container.bounds
    container.addSubview(detail.view)
    container.layoutIfNeeded()

    let context = MockTransitionContext(
        containerView: container,
        fromViewController: detail,       // departing
        toViewController: predecessor,    // revealed
        fromView: detail.view,
        toView: predecessor.view
    )
    context.isInteractiveOverride = true

    let animationDriver = TransitionDriver(transition: transition, phase: .disappearing, operation: .pop)
    let driver = transition.makeInteractionDriver(operation: .pop)
    driver.animationDriver = animationDriver
    driver.wantsInteractiveStart = true

    return InteractivePopScene(
        window: window,
        container: container,
        predecessor: predecessor,
        detail: detail,
        source: source,
        transition: transition,
        animationDriver: animationDriver,
        driver: driver,
        context: context
    )
}
