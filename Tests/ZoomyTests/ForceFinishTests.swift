import XCTest
import UIKit
@testable import Zoomy

/// The spec gate for M7 §1 / §6: drives `TransitionDriver.forceFinish` (rotation / size change /
/// background) through a `MockTransitionContext` and proves the completion barrier stays
/// **exactly-once** even though stopping the animators fires their completions synchronously.
/// Also gates the `SceneBackgroundObserver` window-scene filter.
@MainActor
final class ForceFinishTests: XCTestCase {

    private var savedAssertHandler: (@MainActor (String) -> Void)!

    override func setUp() {
        super.setUp()
        savedAssertHandler = ZoomyAssert.handler
    }

    override func tearDown() {
        ZoomyAssert.handler = savedAssertHandler
        super.tearDown()
    }

    // MARK: - Test doubles

    private final class SpyDelegate: ZoomTransitionDelegate {
        var willBeginCount = 0
        var didEndCount = 0
        var lastResult: ZoomTransition.Result?

        func zoomTransition(_ transition: ZoomTransition, willBegin context: ZoomTransition.Context) {
            willBeginCount += 1
        }

        func zoomTransition(_ transition: ZoomTransition, didEnd context: ZoomTransition.Context,
                            result: ZoomTransition.Result) {
            didEndCount += 1
            lastResult = result
        }
    }

    private struct ModalScene {
        let window: UIWindow
        let container: UIView
        let presenter: UIViewController
        let detail: UIViewController
        let source: UIView
        let transition: ZoomTransition
        let spy: SpyDelegate
    }

    private func makeModalScene(resolvesSource: Bool = true) -> ModalScene {
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
        window.addSubview(container)

        let detail = UIViewController()
        detail.view.backgroundColor = .systemBlue

        let spy = SpyDelegate()
        let transition = ZoomTransition { _ -> UIView? in resolvesSource ? source : nil }
        transition.delegate = spy
        detail.zoomTransition = transition

        return ModalScene(window: window, container: container, presenter: presenter,
                          detail: detail, source: source, transition: transition, spy: spy)
    }

    private func makePresentContext(_ scene: ModalScene) -> MockTransitionContext {
        MockTransitionContext(
            containerView: scene.container,
            fromViewController: scene.presenter,
            toViewController: scene.detail,
            fromView: scene.presenter.view,
            toView: scene.detail.view
        )
    }

    private func makeDismissContext(_ scene: ModalScene) -> MockTransitionContext {
        scene.detail.view.frame = scene.container.bounds
        scene.container.addSubview(scene.detail.view)
        scene.container.layoutIfNeeded()
        return MockTransitionContext(
            containerView: scene.container,
            fromViewController: scene.detail,
            toViewController: scene.presenter,
            fromView: scene.detail.view,
            toView: scene.presenter.view
        )
    }

    private func portalCount(in container: UIView) -> Int {
        container.subviews.filter { $0 is PortalView }.count
    }

    // MARK: - S1: non-interactive present, forced mid-flight

    func test_nonInteractivePresent_forceFinish_completesExactlyOnceAndCleansUp() {
        let scene = makeModalScene()
        let ctx = makePresentContext(scene)
        let driver = TransitionDriver(transition: scene.transition, phase: .appearing, operation: .present)

        driver.animateTransition(using: ctx)
        // Mid-flight: the state machine is animating and the animators are live.
        XCTAssertEqual(scene.transition.stateMachine.state, .animating(.zoomIn))
        XCTAssertNotNil(scene.transition.activeTransition)

        driver.forceFinish(.sizeChange)

        XCTAssertEqual(ctx.completeTransitionCallCount, 1, "completeTransition must fire exactly once")
        XCTAssertEqual(ctx.completeTransitionFlags, [true], "an animating present force-finishes completed")
        XCTAssertFalse(scene.source.isHidden, "source must be unhidden after force-finish")
        XCTAssertEqual(portalCount(in: scene.container), 0, "no portal may remain")
        XCTAssertTrue(scene.detail.view.superview === scene.container)
        XCTAssertEqual(scene.detail.view.transform, .identity)
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertNil(scene.transition.currentDriver)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
        XCTAssertEqual(scene.spy.didEndCount, 1)
        XCTAssertEqual(scene.spy.lastResult,
                       ZoomTransition.Result(isCompleted: true, wasInteractive: false, fallbackReason: nil))
    }

    // MARK: - S2: non-interactive dismiss, forced mid-flight

    func test_nonInteractiveDismiss_forceFinish_completesExactlyOnceAndCleansUp() {
        let scene = makeModalScene()
        let ctx = makeDismissContext(scene)
        let driver = TransitionDriver(transition: scene.transition, phase: .disappearing, operation: .dismiss)

        driver.animateTransition(using: ctx)
        XCTAssertEqual(scene.transition.stateMachine.state, .animating(.zoomOut))

        driver.forceFinish(.sceneBackground)

        XCTAssertEqual(ctx.completeTransitionCallCount, 1)
        XCTAssertEqual(ctx.completeTransitionFlags, [true])
        XCTAssertFalse(scene.source.isHidden)
        XCTAssertEqual(portalCount(in: scene.container), 0)
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
        XCTAssertEqual(scene.spy.lastResult,
                       ZoomTransition.Result(isCompleted: true, wasInteractive: false, fallbackReason: nil))
    }

    // MARK: - S3: force-finish is a no-op once idle (double-call safety)

    func test_forceFinish_whenAlreadyComplete_isNoOp() {
        let scene = makeModalScene()
        let ctx = makePresentContext(scene)
        let driver = TransitionDriver(transition: scene.transition, phase: .appearing, operation: .present)

        driver.animateTransition(using: ctx)
        driver.forceFinish(.sizeChange)
        XCTAssertEqual(ctx.completeTransitionCallCount, 1)

        // A second force-finish (e.g. a background notification arriving right after) must do nothing.
        driver.forceFinish(.sceneBackground)
        XCTAssertEqual(ctx.completeTransitionCallCount, 1, "a second force-finish must not re-complete")
        XCTAssertEqual(scene.spy.didEndCount, 1)
    }

    // MARK: - S4: interactive force-finish — direction rule (progress > 0.5)

    func test_interactive_forceFinish_aboveHalfCompletes() {
        let scene = makeInteractiveDismissScene()
        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 0, y: 760))
        XCTAssertEqual(scene.transition.stateMachine.state, .interactive(.zoomOut))
        XCTAssertGreaterThan(scene.transition.stateMachine.lastProgress, 0.5)

        scene.animationDriver.forceFinish(.sizeChange)

        XCTAssertEqual(scene.context.completeTransitionCallCount, 1, "completeTransition must fire exactly once")
        XCTAssertEqual(scene.context.completeTransitionFlags, [true], "progress > 0.5 → completed")
        XCTAssertEqual(scene.context.finishInteractiveCallCount, 1, "interactive commit reports finish")
        XCTAssertEqual(scene.context.cancelInteractiveCallCount, 0)
        XCTAssertFalse(scene.source.isHidden)
        XCTAssertEqual(portalCount(in: scene.container), 0)
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
    }

    // MARK: - S5: interactive force-finish — direction rule (progress < 0.5)

    func test_interactive_forceFinish_belowHalfCancels() {
        let scene = makeInteractiveDismissScene()
        let finalFrame = scene.context.finalFrame(for: scene.detail)
        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 0, y: 40))
        XCTAssertEqual(scene.transition.stateMachine.state, .interactive(.zoomOut))
        XCTAssertLessThan(scene.transition.stateMachine.lastProgress, 0.5)

        scene.animationDriver.forceFinish(.sceneBackground)

        XCTAssertEqual(scene.context.completeTransitionCallCount, 1)
        XCTAssertEqual(scene.context.completeTransitionFlags, [false], "progress < 0.5 → cancelled")
        XCTAssertEqual(scene.context.cancelInteractiveCallCount, 1)
        XCTAssertEqual(scene.context.finishInteractiveCallCount, 0)
        // Cancel-recovery invariant still holds under a forced finish.
        XCTAssertEqual(scene.detail.view.transform, .identity)
        XCTAssertEqual(scene.detail.view.frame, finalFrame)
        XCTAssertTrue(scene.detail.view.superview === scene.container)
        XCTAssertFalse(scene.source.isHidden)
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
    }

    // MARK: - S6: interactive force-finish during settle — committed direction, no double-fire

    func test_settling_forceFinish_usesCommittedDirectionWithNoDoubleFire() {
        let scene = makeInteractiveDismissScene()
        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 0, y: 240))
        // Downward flick → settle toward completion (live springs + transition animator running).
        scene.pan(.ended, translation: CGPoint(x: 0, y: 240), velocity: CGPoint(x: 0, y: 1_600))
        XCTAssertEqual(scene.transition.stateMachine.state, .settling(.zoomOut, toCompleted: true))
        XCTAssertEqual(scene.context.finishInteractiveCallCount, 1, "settle already committed the direction")

        // Force-finish must stop the live settle springs (whose completions fire synchronously) and
        // still complete exactly once, in the committed direction, without re-reporting finish.
        scene.animationDriver.forceFinish(.sizeChange)

        XCTAssertEqual(scene.context.completeTransitionCallCount, 1, "completeTransition must fire exactly once")
        XCTAssertEqual(scene.context.completeTransitionFlags, [true], "committed (settling) direction")
        XCTAssertEqual(scene.context.finishInteractiveCallCount, 1, "finish must NOT be reported twice")
        XCTAssertFalse(scene.source.isHidden)
        XCTAssertEqual(portalCount(in: scene.container), 0)
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertNil(scene.transition.currentDriver)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
    }

    // MARK: - S7: SceneBackgroundObserver window-scene filter

    func test_sceneBackgroundObserver_firesOnlyForMatchingScene() {
        let sceneA = NSObject()
        let sceneB = NSObject()
        var firedCount = 0
        let observer = SceneBackgroundObserver(scene: sceneA) { firedCount += 1 }

        // A different scene's background is ignored.
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: sceneB)
        XCTAssertEqual(firedCount, 0, "an unrelated scene's notification must be ignored")

        // The observed scene's background fires exactly once.
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: sceneA)
        XCTAssertEqual(firedCount, 1, "the matching scene's notification must fire the callback")

        withExtendedLifetime(observer) {}
    }

    func test_sceneBackgroundObserver_nilScene_neverFires() {
        var firedCount = 0
        let observer = SceneBackgroundObserver(scene: nil) { firedCount += 1 }
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: NSObject())
        XCTAssertEqual(firedCount, 0, "a nil target scene never matches")
        withExtendedLifetime(observer) {}
    }
}
