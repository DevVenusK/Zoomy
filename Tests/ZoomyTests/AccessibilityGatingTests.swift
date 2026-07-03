import XCTest
import UIKit
@testable import Zoomy

/// The spec gate for M7 §2 / §6: Reduce Motion / Prefer Cross-Fade / VoiceOver gating. Because those
/// `UIAccessibility` flags can't be toggled from a unit test, the gating reads an injectable
/// `AccessibilityEnvironment` (production uses the live flags); these tests inject a stub.
@MainActor
final class AccessibilityGatingTests: XCTestCase {

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

    private struct StubAccessibilityEnvironment: AccessibilityEnvironment {
        var isReduceMotionEnabled = false
        var prefersCrossFadeTransitions = false
        var isVoiceOverRunning = false
    }

    private final class SpyDelegate: ZoomTransitionDelegate {
        var didEndCount = 0
        var lastResult: ZoomTransition.Result?
        var didEndExpectation: XCTestExpectation?
        func zoomTransition(_ transition: ZoomTransition, willBegin context: ZoomTransition.Context) {}
        func zoomTransition(_ transition: ZoomTransition, didEnd context: ZoomTransition.Context,
                            result: ZoomTransition.Result) {
            didEndCount += 1
            lastResult = result
            didEndExpectation?.fulfill()
        }
    }

    private struct Scene {
        let window: UIWindow
        let container: UIView
        let presenter: UIViewController
        let detail: UIViewController
        let source: UIView
        let transition: ZoomTransition
        let spy: SpyDelegate
    }

    private func makeScene(respectsReduceMotion: Bool = true) -> Scene {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let presenter = UIViewController()
        presenter.view.frame = window.bounds
        let source = UIView(frame: CGRect(x: 80, y: 320, width: 160, height: 160))
        source.backgroundColor = .systemRed
        presenter.view.addSubview(source)
        window.rootViewController = presenter
        window.isHidden = false

        let container = UIView(frame: window.bounds)
        window.addSubview(container)

        let detail = UIViewController()
        detail.view.backgroundColor = .systemBlue

        var config = ZoomTransition.Configuration()
        config.respectsReduceMotion = respectsReduceMotion
        let spy = SpyDelegate()
        let transition = ZoomTransition(configuration: config) { _ -> UIView? in source }
        transition.delegate = spy
        detail.zoomTransition = transition

        return Scene(window: window, container: container, presenter: presenter,
                     detail: detail, source: source, transition: transition, spy: spy)
    }

    private func portalCount(in container: UIView) -> Int {
        container.subviews.filter { $0 is PortalView }.count
    }

    // MARK: - The seam itself

    func test_accessibilityFallbackReason_reduceMotion() {
        let scene = makeScene()
        scene.transition.accessibilityEnvironment =
            StubAccessibilityEnvironment(isReduceMotionEnabled: true)
        XCTAssertEqual(scene.transition.accessibilityFallbackReason, .reduceMotion)
    }

    func test_accessibilityFallbackReason_prefersCrossFade() {
        let scene = makeScene()
        scene.transition.accessibilityEnvironment =
            StubAccessibilityEnvironment(prefersCrossFadeTransitions: true)
        XCTAssertEqual(scene.transition.accessibilityFallbackReason, .reduceMotion)
    }

    func test_accessibilityFallbackReason_voiceOver_ignoresRespectsReduceMotion() {
        let scene = makeScene(respectsReduceMotion: false)
        scene.transition.accessibilityEnvironment =
            StubAccessibilityEnvironment(isVoiceOverRunning: true)
        // VoiceOver forces cross-dissolve even when Reduce Motion is not respected.
        XCTAssertEqual(scene.transition.accessibilityFallbackReason, .reduceMotion)
        XCTAssertTrue(scene.transition.suppressesInteractionForAccessibility)
    }

    func test_accessibilityFallbackReason_respectsReduceMotionFalse_keepsZoom() {
        let scene = makeScene(respectsReduceMotion: false)
        scene.transition.accessibilityEnvironment =
            StubAccessibilityEnvironment(isReduceMotionEnabled: true, prefersCrossFadeTransitions: true)
        XCTAssertNil(scene.transition.accessibilityFallbackReason, "Reduce Motion is ignored when not respected")
        XCTAssertFalse(scene.transition.suppressesInteractionForAccessibility)
    }

    func test_accessibilityFallbackReason_allOff_isNil() {
        let scene = makeScene()
        scene.transition.accessibilityEnvironment = StubAccessibilityEnvironment()
        XCTAssertNil(scene.transition.accessibilityFallbackReason)
    }

    // MARK: - Adapter vend gating (present / dismiss)

    func test_reduceMotion_presentVend_forcesCrossDissolveDriver() {
        let scene = makeScene()
        scene.transition.accessibilityEnvironment =
            StubAccessibilityEnvironment(isReduceMotionEnabled: true)

        let animator = scene.transition.modalAdapter.animationController(
            forPresented: scene.detail, presenting: scene.presenter, source: scene.presenter
        )
        XCTAssertEqual((animator as? TransitionDriver)?.forcedFallbackReason, .reduceMotion)
    }

    func test_reduceMotion_dismissVend_forcesCrossDissolveDriver() {
        let scene = makeScene()
        scene.transition.accessibilityEnvironment =
            StubAccessibilityEnvironment(isReduceMotionEnabled: true)

        let animator = scene.transition.modalAdapter.animationController(forDismissed: scene.detail)
        XCTAssertEqual((animator as? TransitionDriver)?.forcedFallbackReason, .reduceMotion)
    }

    func test_noAccessibility_presentVend_keepsZoom() {
        let scene = makeScene()
        scene.transition.accessibilityEnvironment = StubAccessibilityEnvironment()
        let animator = scene.transition.modalAdapter.animationController(
            forPresented: scene.detail, presenting: scene.presenter, source: scene.presenter
        )
        XCTAssertNil((animator as? TransitionDriver)?.forcedFallbackReason)
    }

    // MARK: - End-to-end: reduce-motion present reports .reduceMotion and installs no portal

    func test_reduceMotion_present_runsCrossDissolveAndReportsReduceMotion() {
        let scene = makeScene()
        scene.transition.accessibilityEnvironment =
            StubAccessibilityEnvironment(isReduceMotionEnabled: true)

        let ctx = MockTransitionContext(
            containerView: scene.container,
            fromViewController: scene.presenter,
            toViewController: scene.detail,
            fromView: scene.presenter.view,
            toView: scene.detail.view
        )
        let driver = scene.transition.modalAdapter.animationController(
            forPresented: scene.detail, presenting: scene.presenter, source: scene.presenter
        ) as! TransitionDriver

        let exp = expectation(description: "reduce-motion didEnd")
        scene.spy.didEndExpectation = exp
        driver.animateTransition(using: ctx)
        waitForExpectations(timeout: 5)

        XCTAssertEqual(ctx.completeTransitionCallCount, 1)
        XCTAssertEqual(portalCount(in: scene.container), 0, "cross-dissolve installs no portal")
        XCTAssertFalse(scene.source.isHidden, "cross-dissolve never hides the source")
        XCTAssertEqual(scene.spy.lastResult,
                       ZoomTransition.Result(isCompleted: true, wasInteractive: false, fallbackReason: .reduceMotion))
    }

    // MARK: - Navigation vend gating

    func test_reduceMotion_pushVend_forcesCrossDissolveDriver() {
        let scene = makeScene()
        scene.transition.accessibilityEnvironment =
            StubAccessibilityEnvironment(isReduceMotionEnabled: true)
        // A fresh nav with its own root (scene.presenter is already a window root VC).
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)

        let proxy = ZoomNavigationDelegate()
        let animator = proxy.navigationController(
            nav, animationControllerFor: .push, from: root, to: scene.detail
        )
        XCTAssertEqual((animator as? TransitionDriver)?.forcedFallbackReason, .reduceMotion)
    }

    // MARK: - VoiceOver suppresses interactive dismissal

    func test_voiceOver_installsPanDisabled_andRefusesToBegin() {
        let scene = makeScene()
        scene.transition.accessibilityEnvironment =
            StubAccessibilityEnvironment(isVoiceOverRunning: true)

        let interactionDriver = scene.transition.makeInteractionDriver(operation: .dismiss)
        interactionDriver.installGesture(on: scene.detail.view)
        XCTAssertFalse(interactionDriver.panGesture.isEnabled, "VoiceOver installs the pan disabled")

        let mockPan = MockPanGestureRecognizer()
        mockPan.mockView = scene.detail.view
        mockPan.mockTranslation = CGPoint(x: 0, y: 200)
        XCTAssertFalse(interactionDriver.gestureRecognizerShouldBegin(mockPan),
                       "VoiceOver must refuse the interactive dismissal")
    }

    func test_noVoiceOver_installsPanEnabled() {
        let scene = makeScene()
        scene.transition.accessibilityEnvironment = StubAccessibilityEnvironment()
        let interactionDriver = scene.transition.makeInteractionDriver(operation: .dismiss)
        interactionDriver.installGesture(on: scene.detail.view)
        XCTAssertTrue(interactionDriver.panGesture.isEnabled, "without VoiceOver the pan is enabled")
    }
}
