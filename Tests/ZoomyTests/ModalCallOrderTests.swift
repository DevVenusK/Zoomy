import XCTest
import UIKit
import ZoomyCore
@testable import Zoomy

/// The spec gate for M3b (brief §9): drives `TransitionDriver` directly through a
/// `MockTransitionContext` and asserts the completion/cleanup contract for present, dismiss,
/// fallback, reentrancy, memory, and callback ordering.
@MainActor
final class ModalCallOrderTests: XCTestCase {

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
        var didEndExpectation: XCTestExpectation?

        func zoomTransition(_ transition: ZoomTransition, willBegin context: ZoomTransition.Context) {
            willBeginCount += 1
        }

        func zoomTransition(_ transition: ZoomTransition, didEnd context: ZoomTransition.Context,
                            result: ZoomTransition.Result) {
            didEndCount += 1
            lastResult = result
            didEndExpectation?.fulfill()
        }
    }

    private final class ProviderProbe {
        var callCount = 0
        var sawWillBeginBeforeFirstCall = false
    }

    private struct Scene {
        let window: UIWindow
        let container: UIView
        let presenter: UIViewController
        let detail: UIViewController
        let source: UIView
        let transition: ZoomTransition
        let spy: SpyDelegate
        let probe: ProviderProbe
    }

    private func makeScene(resolvesSource: Bool = true) -> Scene {
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

        let detail = UIViewController()
        detail.view.backgroundColor = .systemBlue

        let spy = SpyDelegate()
        let probe = ProviderProbe()

        let transition = ZoomTransition { [weak spy] _ -> UIView? in
            if probe.callCount == 0 {
                probe.sawWillBeginBeforeFirstCall = (spy?.willBeginCount ?? 0) >= 1
            }
            probe.callCount += 1
            return resolvesSource ? source : nil
        }
        transition.delegate = spy
        detail.zoomTransition = transition

        return Scene(
            window: window,
            container: container,
            presenter: presenter,
            detail: detail,
            source: source,
            transition: transition,
            spy: spy,
            probe: probe
        )
    }

    private func makePresentContext(_ scene: Scene) -> MockTransitionContext {
        MockTransitionContext(
            containerView: scene.container,
            fromViewController: scene.presenter,
            toViewController: scene.detail,
            fromView: scene.presenter.view,
            toView: scene.detail.view
        )
    }

    private func makeDismissContext(_ scene: Scene) -> MockTransitionContext {
        // The destination is already "presented": its view sits in the container.
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

    // MARK: - S1: present completes

    func test_present_completesExactlyOnceAndCleansUp() {
        let scene = makeScene()
        let ctx = makePresentContext(scene)
        let driver = TransitionDriver(transition: scene.transition, phase: .appearing, operation: .present)

        let exp = expectation(description: "present didEnd")
        scene.spy.didEndExpectation = exp
        driver.animateTransition(using: ctx)
        waitForExpectations(timeout: 5)

        XCTAssertEqual(ctx.completeTransitionCallCount, 1)
        XCTAssertEqual(ctx.completeTransitionFlags, [true])
        XCTAssertFalse(scene.source.isHidden, "source must be unhidden after completion")
        XCTAssertEqual(portalCount(in: scene.container), 0, "no portal may remain in the container")
        XCTAssertTrue(scene.detail.view.superview === scene.container,
                      "the live view must land as a direct child of the container")
        XCTAssertEqual(scene.detail.view.transform, .identity)
        XCTAssertEqual(scene.detail.view.frame, ctx.finalFrame(for: scene.detail))
        XCTAssertEqual(scene.spy.didEndCount, 1)
        XCTAssertEqual(
            scene.spy.lastResult,
            ZoomTransition.Result(isCompleted: true, wasInteractive: false, fallbackReason: nil)
        )
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
    }

    // MARK: - S2: dismiss completes

    func test_dismiss_completesExactlyOnceAndCleansUp() {
        let scene = makeScene()
        let ctx = makeDismissContext(scene)
        let driver = TransitionDriver(transition: scene.transition, phase: .disappearing, operation: .dismiss)

        let exp = expectation(description: "dismiss didEnd")
        scene.spy.didEndExpectation = exp
        driver.animateTransition(using: ctx)
        waitForExpectations(timeout: 5)

        XCTAssertEqual(ctx.completeTransitionCallCount, 1)
        XCTAssertEqual(ctx.completeTransitionFlags, [true])
        XCTAssertFalse(scene.source.isHidden, "source must be unhidden after completion")
        XCTAssertEqual(portalCount(in: scene.container), 0, "no portal may remain in the container")
        XCTAssertEqual(scene.spy.didEndCount, 1)
        XCTAssertEqual(
            scene.spy.lastResult,
            ZoomTransition.Result(isCompleted: true, wasInteractive: false, fallbackReason: nil)
        )
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
    }

    // MARK: - S3: fallback (provider returns nil)

    func test_present_withUnresolvableSource_fallsBackToCrossDissolveAndCompletes() {
        let scene = makeScene(resolvesSource: false)
        let ctx = makePresentContext(scene)
        let driver = TransitionDriver(transition: scene.transition, phase: .appearing, operation: .present)

        let exp = expectation(description: "fallback didEnd")
        scene.spy.didEndExpectation = exp
        driver.animateTransition(using: ctx)
        waitForExpectations(timeout: 5)

        XCTAssertEqual(ctx.completeTransitionCallCount, 1)
        XCTAssertEqual(ctx.completeTransitionFlags, [true])
        XCTAssertEqual(portalCount(in: scene.container), 0, "cross-dissolve installs no portal")
        XCTAssertTrue(scene.detail.view.superview === scene.container)
        XCTAssertEqual(scene.detail.view.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(scene.spy.didEndCount, 1)
        XCTAssertEqual(
            scene.spy.lastResult,
            ZoomTransition.Result(isCompleted: true, wasInteractive: false, fallbackReason: .sourceUnresolved)
        )
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
    }

    // MARK: - S4: reentrancy

    func test_adapter_whenNotIdle_returnsNilWithoutReportingDidEnd() {
        let scene = makeScene()
        // Force the state machine out of `.idle`.
        scene.transition.stateMachine.handle(.begin(.zoomIn, interactive: false))
        XCTAssertNotEqual(scene.transition.stateMachine.state, .idle)

        let present = scene.transition.modalAdapter.animationController(
            forPresented: scene.detail, presenting: scene.presenter, source: scene.presenter
        )
        let dismiss = scene.transition.modalAdapter.animationController(forDismissed: scene.detail)

        XCTAssertNil(present, "a non-idle present vend must return nil (system default)")
        XCTAssertNil(dismiss, "a non-idle dismiss vend must return nil (system default)")
        XCTAssertEqual(scene.spy.didEndCount, 0, "reentrant rejection must not report a Result")
        XCTAssertEqual(scene.spy.willBeginCount, 0)
    }

    // MARK: - S5: memory

    func test_memory_driverPortalAndTransitionDeallocateAfterCompletion() {
        weak var weakDriver: TransitionDriver?
        weak var weakPortal: PortalView?
        weak var weakTransition: ZoomTransition?
        weak var weakDetail: UIViewController?

        autoreleasepool {
            let scene = makeScene()
            let ctx = makePresentContext(scene)
            var driver: TransitionDriver? =
                TransitionDriver(transition: scene.transition, phase: .appearing, operation: .present)

            weakDriver = driver
            weakTransition = scene.transition
            weakDetail = scene.detail

            let exp = expectation(description: "memory didEnd")
            scene.spy.didEndExpectation = exp
            driver?.animateTransition(using: ctx)
            weakPortal = scene.container.subviews.compactMap { $0 as? PortalView }.first
            XCTAssertNotNil(weakPortal, "a portal must exist mid-transition")
            waitForExpectations(timeout: 5)

            driver = nil
            // Detach the transition so the only remaining owner is `detail`, which drops here.
            scene.detail.view.removeFromSuperview()
            scene.window.isHidden = true
            scene.window.rootViewController = nil
        }

        XCTAssertNil(weakDriver, "driver must deallocate after the transition")
        XCTAssertNil(weakPortal, "portal must deallocate after cleanup")
        XCTAssertNil(weakDetail, "destination view controller must deallocate")
        XCTAssertNil(weakTransition, "transition must deallocate with its view controller")
    }

    // MARK: - S6: willBegin ordering

    func test_willBegin_isReportedBeforeSourceResolution() {
        let scene = makeScene()
        let ctx = makePresentContext(scene)
        let driver = TransitionDriver(transition: scene.transition, phase: .appearing, operation: .present)

        let exp = expectation(description: "order didEnd")
        scene.spy.didEndExpectation = exp
        driver.animateTransition(using: ctx)
        waitForExpectations(timeout: 5)

        XCTAssertGreaterThanOrEqual(scene.probe.callCount, 1, "the provider must have been called")
        XCTAssertTrue(scene.probe.sawWillBeginBeforeFirstCall,
                      "willBegin must fire before the source provider is invoked")
        XCTAssertEqual(scene.spy.willBeginCount, 1)
    }
}
