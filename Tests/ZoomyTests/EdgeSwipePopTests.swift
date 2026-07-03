import XCTest
import UIKit
@testable import Zoomy

/// The spec gate for M5's edge-swipe pop wiring (brief §1–§3): the coordinator is installed on a
/// zoom screen, the system `interactivePopGestureRecognizer` is suppressed on a zoom screen but
/// delegated to its original delegate off zoom, our edge pan begins only on an idle zoom screen and
/// never at the root, an edge-initiated pop triggers `popViewController` and vends the interactive
/// driver, and a nav that never shows a zoom screen keeps its stock pop entirely untouched.
///
/// `simctl` cannot synthesize a real screen-edge swipe, so — as the brief permits — the gesture path
/// is driven by calling the coordinator's handler directly with a `MockPanGestureRecognizer` and by
/// invoking the arbitrator's delegate methods; the M4/M6 suites remain the regression gate.
@MainActor
final class EdgeSwipePopTests: XCTestCase {

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

    /// Records `popViewController` without running a real transition, so the edge-began path can be
    /// verified without UIKit's animation machinery (brief §3: "핸들러 직접 호출 + mock nav").
    private final class SpyNavigationController: UINavigationController {
        private(set) var popCount = 0
        override func popViewController(animated: Bool) -> UIViewController? {
            popCount += 1
            return nil
        }
    }

    /// A stand-in for the original system-recognizer delegate, so delegation off a zoom screen can be
    /// asserted deterministically.
    private final class SpyGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        var shouldBeginResult = true
        private(set) var shouldBeginCallCount = 0
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            shouldBeginCallCount += 1
            return shouldBeginResult
        }
    }

    // MARK: - Fixtures

    private func makeZoomTransition(resolvesSource: Bool = true) -> (ZoomTransition, UIView) {
        let source = UIView(frame: CGRect(x: 40, y: 200, width: 120, height: 120))
        let transition = ZoomTransition { _ -> UIView? in resolvesSource ? source : nil }
        return (transition, source)
    }

    /// A live nav in a visible window (so `interactivePopGestureRecognizer` exists), rooted at
    /// `root` with `detail` pushed as an adjacent zoom (`pushPredecessor = root`). `enableZoomTransitions`
    /// installs the proxy; the caller then drives `didShow` to install the edge coordinator.
    @MainActor
    private func makeWindowedZoomNav()
        -> (window: UIWindow, nav: UINavigationController, root: UIViewController,
            detail: UIViewController, transition: ZoomTransition, proxy: ZoomNavigationDelegate) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        window.rootViewController = nav
        window.makeKeyAndVisible()

        let detail = UIViewController()
        let (transition, source) = makeZoomTransition()
        root.view.addSubview(source)
        detail.zoomTransition = transition
        transition.pushPredecessor = root
        nav.setViewControllers([root, detail], animated: false)

        let proxy = nav.enableZoomTransitions()
        return (window, nav, root, detail, transition, proxy)
    }

    private func teardown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func systemRecognizer(_ nav: UINavigationController) throws -> UIGestureRecognizer {
        try XCTUnwrap(nav.interactivePopGestureRecognizer, "the nav must expose interactivePopGestureRecognizer")
    }

    // MARK: - Installation wiring (§3: zoom 화면 배선)

    func test_zoomScreen_didShow_installsEdgePanAndArbitratesSystemRecognizer() throws {
        let (window, nav, _, detail, _, proxy) = makeWindowedZoomNav()
        defer { teardown(window) }

        let system = try systemRecognizer(nav)
        let originalSystemDelegate = system.delegate

        proxy.navigationController(nav, didShow: detail, animated: false)

        let coordinator = try XCTUnwrap(proxy.edgePopCoordinator, "a zoom screen must install the edge coordinator")
        let edge = try XCTUnwrap(coordinator.edgePanGesture, "the coordinator must own a left-edge pan")

        XCTAssertEqual(edge.edges, .left, "our edge pan must be a left-edge screen-edge pan")
        XCTAssertTrue(nav.view.gestureRecognizers?.contains(where: { $0 === edge }) ?? false,
                      "our edge pan must be installed on the nav view")
        XCTAssertTrue(system.delegate === coordinator,
                      "the system recognizer's delegate must be swapped to our arbitrator")
        XCTAssertTrue(coordinator.originalPopDelegate === originalSystemDelegate,
                      "the arbitrator must preserve the original system-recognizer delegate")
    }

    func test_installIsIdempotent_acrossRepeatedDidShow() throws {
        let (window, nav, _, detail, _, proxy) = makeWindowedZoomNav()
        defer { teardown(window) }

        proxy.navigationController(nav, didShow: detail, animated: false)
        let coordinator = try XCTUnwrap(proxy.edgePopCoordinator)
        let edge = coordinator.edgePanGesture

        proxy.navigationController(nav, didShow: detail, animated: false)

        XCTAssertTrue(proxy.edgePopCoordinator === coordinator, "the coordinator must not be recreated")
        XCTAssertTrue(coordinator.edgePanGesture === edge, "a second install must not add a second edge pan")
        let ourEdges = nav.view.gestureRecognizers?.filter { $0 === edge }.count ?? 0
        XCTAssertEqual(ourEdges, 1, "our edge pan must be installed exactly once")
    }

    // MARK: - System-recognizer suppression on zoom (§3: 시스템 recognizer 억제)

    func test_zoomScreen_suppressesSystemRecognizer() throws {
        let (window, nav, _, detail, _, proxy) = makeWindowedZoomNav()
        defer { teardown(window) }
        proxy.navigationController(nav, didShow: detail, animated: false)
        let coordinator = try XCTUnwrap(proxy.edgePopCoordinator)
        let system = try systemRecognizer(nav)

        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(system),
                       "on a zoom screen the system recognizer must refuse to begin (our edge pan drives the pop)")
    }

    // MARK: - Off-zoom delegation to the original delegate (§3: 스톡 보존)

    func test_nonZoomScreen_systemRecognizer_delegatesToOriginalDelegate() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        let plain = UIViewController() // no zoomTransition → non-zoom top
        let nav = UINavigationController(rootViewController: root)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer { teardown(window) }
        nav.setViewControllers([root, plain], animated: false)

        let spy = SpyGestureDelegate()
        let system = try systemRecognizer(nav)
        system.delegate = spy // prime the "original" delegate before we install

        let coordinator = ZoomEdgePopCoordinator(navigationController: nav)
        coordinator.installIfNeeded()
        XCTAssertTrue(coordinator.originalPopDelegate === spy, "install must capture the original delegate")

        spy.shouldBeginResult = true
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(system),
                      "off a zoom screen the arbitrator must delegate to the original delegate (true)")
        XCTAssertEqual(spy.shouldBeginCallCount, 1, "the original delegate must actually be consulted")

        spy.shouldBeginResult = false
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(system),
                       "off a zoom screen the arbitrator must honour the original delegate (false)")
    }

    func test_nonZoomScreen_nilOriginalDelegate_systemRecognizerBeginsByDefault() {
        let root = UIViewController()
        let plain = UIViewController() // non-zoom top
        let nav = UINavigationController(rootViewController: root)
        nav.setViewControllers([root, plain], animated: false)

        // A coordinator whose original delegate is nil (never captured). Any recognizer that is not
        // our edge pan takes the system branch.
        let coordinator = ZoomEdgePopCoordinator(navigationController: nav)
        XCTAssertNil(coordinator.originalPopDelegate)

        let standIn = UIScreenEdgePanGestureRecognizer()
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(standIn),
                      "with no original delegate the system recognizer must begin by default (stock pop preserved)")
    }

    // MARK: - Our edge pan begin gating (§3: 우리 edge pan + 루트 가드)

    func test_ownEdgePan_beginsOnIdleZoomScreen() throws {
        let (window, nav, _, detail, _, proxy) = makeWindowedZoomNav()
        defer { teardown(window) }
        proxy.navigationController(nav, didShow: detail, animated: false)
        let coordinator = try XCTUnwrap(proxy.edgePopCoordinator)
        let edge = try XCTUnwrap(coordinator.edgePanGesture)

        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(edge),
                      "our edge pan must begin on an idle, poppable zoom screen")
    }

    func test_ownEdgePan_refusesWhenTransitionNotIdle() throws {
        let (window, nav, _, detail, transition, proxy) = makeWindowedZoomNav()
        defer { teardown(window) }
        proxy.navigationController(nav, didShow: detail, animated: false)
        let coordinator = try XCTUnwrap(proxy.edgePopCoordinator)
        let edge = try XCTUnwrap(coordinator.edgePanGesture)

        // Force the transition out of idle (a pop is already in flight).
        transition.stateMachine.handle(.begin(.zoomOut, interactive: true))
        XCTAssertNotEqual(transition.stateMachine.state, .idle)

        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(edge),
                       "our edge pan must not begin a second pop while one is in flight")
    }

    func test_ownEdgePan_doesNotBeginAtRoot() throws {
        let (window, nav, root, detail, _, proxy) = makeWindowedZoomNav()
        defer { teardown(window) }
        proxy.navigationController(nav, didShow: detail, animated: false)
        let coordinator = try XCTUnwrap(proxy.edgePopCoordinator)
        let edge = try XCTUnwrap(coordinator.edgePanGesture)

        // Simulate having popped back to the root (count == 1).
        nav.setViewControllers([root], animated: false)

        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(edge),
                       "there is no pop at the root — our edge pan must refuse to begin")
    }

    // MARK: - Gesture-initiated pop vends the interactive driver (§3)

    func test_edgePanBegan_triggersPopAndVendsInteractionDriver() throws {
        let root = UIViewController()
        let detail = UIViewController()
        let (transition, source) = makeZoomTransition()
        root.view.addSubview(source)
        detail.zoomTransition = transition
        transition.pushPredecessor = root

        let spyNav = SpyNavigationController(rootViewController: root)
        spyNav.setViewControllers([root, detail], animated: false)
        XCTAssertTrue(detail.navigationController === spyNav)

        let coordinator = ZoomEdgePopCoordinator(navigationController: spyNav)

        // Simulate the edge pan crossing into .began.
        let gesture = MockPanGestureRecognizer()
        gesture.mockView = detail.view
        gesture.mockState = .began
        gesture.mockTranslation = CGPoint(x: 24, y: 0)
        coordinator.handleEdgePan(gesture)

        XCTAssertEqual(spyNav.popCount, 1, "the edge began must trigger popViewController")
        let interactionDriver = try XCTUnwrap(transition.interactionDriver,
                                              "the interactive pop driver must have been created")
        XCTAssertTrue(interactionDriver.wantsInteractiveStart,
                      "an edge-initiated pop must mark the driver gesture-initiated")
        XCTAssertTrue(interactionDriver.isGestureActive,
                      "the registered edge gesture must make the driver read as gesture-active")

        // The proxy must now pair the interactive driver for the vended pop animator.
        let proxy = ZoomNavigationDelegate()
        let popAnimator = TransitionDriver(transition: transition, phase: .disappearing, operation: .pop)
        let vended = proxy.navigationController(spyNav, interactionControllerFor: popAnimator)
        XCTAssertTrue(vended === interactionDriver,
                      "interactionControllerFor must vend our interaction driver for a gesture-active pop")
        XCTAssertTrue(interactionDriver.wantsInteractiveStart)
    }

    // MARK: - Stock preservation on a non-zoom nav (§2)

    func test_nonZoomNav_neverInstallsCoordinator_leavesSystemRecognizerUntouched() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        let plain = UIViewController() // pushed screen with NO zoom
        let nav = UINavigationController(rootViewController: root)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer { teardown(window) }
        nav.setViewControllers([root, plain], animated: false)

        let system = try systemRecognizer(nav)
        let originalDelegate = system.delegate
        let recognizersBefore = Set((nav.view.gestureRecognizers ?? []).map { ObjectIdentifier($0) })

        let proxy = nav.enableZoomTransitions()
        proxy.navigationController(nav, didShow: plain, animated: false)

        XCTAssertNil(proxy.edgePopCoordinator,
                     "a nav that never shows a zoom screen must not install the edge coordinator")
        XCTAssertTrue(system.delegate === originalDelegate,
                      "the system recognizer's delegate must be untouched on a non-zoom nav (stock pop preserved)")
        let recognizersAfter = Set((nav.view.gestureRecognizers ?? []).map { ObjectIdentifier($0) })
        XCTAssertEqual(recognizersBefore, recognizersAfter,
                       "no Zoomy edge pan may be added on a non-zoom nav")
    }
}
