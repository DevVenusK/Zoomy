import XCTest
import UIKit
import ZoomyCore
@testable import Zoomy

/// Vend-rule coverage for `ZoomNavigationDelegate.navigationController(_:animationControllerFor:…)`
/// and `UINavigationController.enableZoomTransitions()` (brief §3 / §4).
@MainActor
final class ZoomNavigationDelegateTests: XCTestCase {

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

    private final class DummyAnimator: NSObject, UIViewControllerAnimatedTransitioning {
        func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0 }
        func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {}
    }

    /// A downstream that vends its own animator, so we can prove the proxy delegates when it has no
    /// zoom of its own to vend.
    private final class VendingDownstream: NSObject, UINavigationControllerDelegate {
        let animator: any UIViewControllerAnimatedTransitioning
        private(set) var callCount = 0
        init(animator: any UIViewControllerAnimatedTransitioning) { self.animator = animator }
        func navigationController(
            _ navigationController: UINavigationController,
            animationControllerFor operation: UINavigationController.Operation,
            from fromVC: UIViewController,
            to toVC: UIViewController
        ) -> (any UIViewControllerAnimatedTransitioning)? {
            callCount += 1
            return animator
        }
    }

    private func makeTransition() -> ZoomTransition {
        ZoomTransition(sourceViewProvider: { _ in nil })
    }

    private func makeProxy(downstream: (any UINavigationControllerDelegate)? = nil) -> ZoomNavigationDelegate {
        ZoomNavigationDelegate(forwardingTo: downstream)
    }

    private let nav = UINavigationController()

    // MARK: - push

    func test_push_withIdleZoomTransition_vendsAppearingPushDriverAndRecordsPredecessor() {
        let fromVC = UIViewController()
        let toVC = UIViewController()
        let transition = makeTransition()
        toVC.zoomTransition = transition

        let result = makeProxy().navigationController(
            nav, animationControllerFor: .push, from: fromVC, to: toVC
        )

        let driver = try? XCTUnwrap(result as? TransitionDriver)
        XCTAssertNotNil(driver, "push with an idle zoomTransition must vend a TransitionDriver")
        if case .appearing = driver!.phase {} else { XCTFail("phase must be .appearing") }
        if case .push = driver!.operation {} else { XCTFail("operation must be .push") }
        XCTAssertTrue(driver!.transition === transition)
        XCTAssertTrue(transition.pushPredecessor === fromVC, "push vend must record pushPredecessor = fromVC")
    }

    func test_push_withoutZoomTransition_andNoDownstream_returnsNil() {
        let result = makeProxy().navigationController(
            nav, animationControllerFor: .push, from: UIViewController(), to: UIViewController()
        )
        XCTAssertNil(result)
    }

    func test_push_withoutZoomTransition_delegatesToDownstream() {
        let dummy = DummyAnimator()
        let downstream = VendingDownstream(animator: dummy)

        let result = makeProxy(downstream: downstream).navigationController(
            nav, animationControllerFor: .push, from: UIViewController(), to: UIViewController()
        )

        XCTAssertTrue(result === dummy, "with no zoom of its own, the proxy must return the downstream's animator")
        XCTAssertEqual(downstream.callCount, 1)
    }

    func test_push_whenStateMachineNotIdle_returnsNilWithoutVending() {
        let toVC = UIViewController()
        let transition = makeTransition()
        toVC.zoomTransition = transition
        // Force the state machine out of `.idle`.
        transition.stateMachine.handle(.begin(.zoomIn, interactive: false))
        XCTAssertNotEqual(transition.stateMachine.state, .idle)

        let result = makeProxy().navigationController(
            nav, animationControllerFor: .push, from: UIViewController(), to: toVC
        )

        XCTAssertNil(result, "a reentrant push vend must fall through to the system default")
    }

    // MARK: - pop

    func test_pop_adjacent_vendsDisappearingPopDriver() {
        let predecessor = UIViewController()
        let fromVC = UIViewController()
        let transition = makeTransition()
        fromVC.zoomTransition = transition
        transition.pushPredecessor = predecessor

        let result = makeProxy().navigationController(
            nav, animationControllerFor: .pop, from: fromVC, to: predecessor
        )

        let driver = try? XCTUnwrap(result as? TransitionDriver)
        XCTAssertNotNil(driver, "an adjacent pop back to the pushPredecessor must vend a driver")
        if case .disappearing = driver!.phase {} else { XCTFail("phase must be .disappearing") }
        if case .pop = driver!.operation {} else { XCTFail("operation must be .pop") }
        XCTAssertTrue(driver!.transition === transition)
    }

    func test_pop_nonAdjacent_returnsNil() {
        let fromVC = UIViewController()
        let recordedPredecessor = UIViewController() // held strong; weak pushPredecessor must survive
        let popTarget = UIViewController()           // a *different* VC (a multi-level pop / popToRoot)
        let transition = makeTransition()
        fromVC.zoomTransition = transition
        transition.pushPredecessor = recordedPredecessor

        let result = makeProxy().navigationController(
            nav, animationControllerFor: .pop, from: fromVC, to: popTarget
        )

        XCTAssertNil(result, "a non-adjacent pop must fall through to the system default")
    }

    func test_pop_whenStateMachineNotIdle_returnsNil() {
        let predecessor = UIViewController()
        let fromVC = UIViewController()
        let transition = makeTransition()
        fromVC.zoomTransition = transition
        transition.pushPredecessor = predecessor
        transition.stateMachine.handle(.begin(.zoomOut, interactive: false))

        let result = makeProxy().navigationController(
            nav, animationControllerFor: .pop, from: fromVC, to: predecessor
        )

        XCTAssertNil(result, "a reentrant pop vend must fall through to the system default")
    }

    // MARK: - none (setViewControllers)

    func test_operationNone_returnsNil() {
        let result = makeProxy().navigationController(
            nav, animationControllerFor: .none, from: UIViewController(), to: UIViewController()
        )
        XCTAssertNil(result, "a .none operation (setViewControllers) must use the system default")
    }

    func test_operationNone_delegatesToDownstream() {
        let dummy = DummyAnimator()
        let downstream = VendingDownstream(animator: dummy)
        let result = makeProxy(downstream: downstream).navigationController(
            nav, animationControllerFor: .none, from: UIViewController(), to: UIViewController()
        )
        XCTAssertTrue(result === dummy)
    }

    // MARK: - enableZoomTransitions

    func test_enableZoomTransitions_isIdempotent() {
        let navController = UINavigationController()
        let first = navController.enableZoomTransitions()
        let second = navController.enableZoomTransitions()

        XCTAssertTrue(first === second, "a second call must return the same proxy instance")
        XCTAssertTrue(navController.delegate === first, "the proxy must remain the delegate")
    }

    func test_enableZoomTransitions_wrapsExistingDelegateAsDownstream() {
        final class ExistingDelegate: NSObject, UINavigationControllerDelegate {}
        let navController = UINavigationController()
        let existing = ExistingDelegate()
        navController.delegate = existing

        let proxy = navController.enableZoomTransitions()

        XCTAssertTrue(navController.delegate === proxy)
        XCTAssertTrue(proxy.downstream === existing, "the pre-existing delegate must become the downstream")
        XCTAssertTrue(proxy.navigationController === navController)
    }
}
