import XCTest
import UIKit
@testable import Zoomy

/// The interactive spec gate (brief §8): drives `ZoomInteractionDriver` through a
/// `MockTransitionContext` and asserts the completion contract for an interactive complete, an
/// interactive cancel, a grab-then-cancel, and memory. Exactly-once `completeTransition` (from the
/// last animator), the cancel-recovery re-stamp, source unhide, and a `wasInteractive` result are
/// the load-bearing assertions. (The non-interactive regression is `ModalCallOrderTests`.)
@MainActor
final class InteractiveCallOrderTests: XCTestCase {

    private var savedAssertHandler: (@MainActor (String) -> Void)!

    override func setUp() {
        super.setUp()
        savedAssertHandler = ZoomyAssert.handler
    }

    override func tearDown() {
        ZoomyAssert.handler = savedAssertHandler
        super.tearDown()
    }

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

    private func portalCount(in container: UIView) -> Int {
        container.subviews.filter { $0 is PortalView }.count
    }

    // MARK: - S1: interactive complete

    func test_interactiveComplete_finishesExactlyOnceFromLastAnimatorAndCleansUp() {
        let spy = SpyDelegate()
        let exp = expectation(description: "interactive complete didEnd")
        spy.didEndExpectation = exp
        let scene = makeInteractiveDismissScene(delegate: spy)

        scene.start()
        XCTAssertEqual(spy.willBeginCount, 1, "willBegin fires during interactive staging")
        scene.pan(.changed, translation: CGPoint(x: 0, y: 200))
        scene.pan(.changed, translation: CGPoint(x: 0, y: 320))
        scene.pan(.ended, translation: CGPoint(x: 0, y: 320), velocity: CGPoint(x: 0, y: 1_600))

        // finish is synchronous at release; completeTransition is deferred to the barrier.
        XCTAssertEqual(scene.context.finishInteractiveCallCount, 1)
        XCTAssertEqual(scene.context.cancelInteractiveCallCount, 0)
        XCTAssertEqual(scene.context.completeTransitionCallCount, 0, "completeTransition waits for the last animator")

        waitForExpectations(timeout: 5)

        XCTAssertEqual(scene.context.completeTransitionCallCount, 1)
        XCTAssertEqual(scene.context.completeTransitionFlags, [true])
        XCTAssertEqual(scene.context.eventLog.filter { $0 == "finish" || $0.hasPrefix("complete") },
                       ["finish", "complete(true)"], "finish must precede completeTransition")
        XCTAssertFalse(scene.source.isHidden, "source must be unhidden after completion")
        XCTAssertEqual(portalCount(in: scene.container), 0, "no portal may remain after a completed dismiss")
        XCTAssertEqual(spy.didEndCount, 1)
        XCTAssertEqual(spy.lastResult, ZoomTransition.Result(isCompleted: true, wasInteractive: true, fallbackReason: nil))
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertNil(scene.transition.currentDriver)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
    }

    // MARK: - S2: interactive cancel

    func test_interactiveCancel_reversesAndRestoresIdentityAndFinalFrame() {
        let spy = SpyDelegate()
        let exp = expectation(description: "interactive cancel didEnd")
        spy.didEndExpectation = exp
        let scene = makeInteractiveDismissScene(delegate: spy)
        let finalFrame = scene.context.finalFrame(for: scene.detail)

        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 0, y: 90))
        scene.pan(.ended, translation: CGPoint(x: 0, y: 90), velocity: CGPoint(x: 0, y: -1_200))

        // cancel is synchronous; the transition animator must be reversed (never scrubbed backward).
        XCTAssertEqual(scene.context.cancelInteractiveCallCount, 1)
        XCTAssertEqual(scene.context.finishInteractiveCallCount, 0)
        XCTAssertEqual(scene.transition.activeTransition?.transitionAnimator.isReversed, true)
        XCTAssertEqual(scene.context.completeTransitionCallCount, 0)

        waitForExpectations(timeout: 5)

        XCTAssertEqual(scene.context.completeTransitionCallCount, 1)
        XCTAssertEqual(scene.context.completeTransitionFlags, [false])
        XCTAssertEqual(scene.context.eventLog.filter { $0 == "cancel" || $0.hasPrefix("complete") },
                       ["cancel", "complete(false)"], "cancel must precede completeTransition")

        // Cancel-recovery invariant: the departing view is re-stamped to identity + finalFrame,
        // back in the container.
        XCTAssertEqual(scene.detail.view.transform, .identity)
        XCTAssertEqual(scene.detail.view.frame, finalFrame)
        XCTAssertTrue(scene.detail.view.superview === scene.container)
        XCTAssertFalse(scene.source.isHidden, "source must be unhidden after a cancel")
        XCTAssertEqual(portalCount(in: scene.container), 0)
        XCTAssertEqual(spy.lastResult, ZoomTransition.Result(isCompleted: false, wasInteractive: true, fallbackReason: nil))
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
    }

    // MARK: - S3: grab-then-cancel (settle-time re-grab)

    func test_grabThenCancel_completesExactlyOnceWithNoDoubleFire() {
        let spy = SpyDelegate()
        let exp = expectation(description: "grab then cancel didEnd")
        spy.didEndExpectation = exp
        let scene = makeInteractiveDismissScene(delegate: spy)
        let finalFrame = scene.context.finalFrame(for: scene.detail)

        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 0, y: 240))
        // 1st release: downward flick → settle toward completion (transition animator runs forward).
        scene.pan(.ended, translation: CGPoint(x: 0, y: 240), velocity: CGPoint(x: 0, y: 1_400))
        XCTAssertEqual(scene.transition.stateMachine.state, .settling(.zoomOut, toCompleted: true))

        // Re-grab mid-settle → back to interactive (freeze-and-rebuild); no completion yet.
        scene.pan(.began, translation: .zero)
        XCTAssertEqual(scene.transition.stateMachine.state, .interactive(.zoomOut))
        scene.pan(.changed, translation: CGPoint(x: 0, y: 40))
        // 2nd release: upward → cancel.
        scene.pan(.ended, translation: CGPoint(x: 0, y: 40), velocity: CGPoint(x: 0, y: -1_400))

        waitForExpectations(timeout: 5)

        // Exactly one completeTransition (no double-fire from the frozen first-settle springs).
        XCTAssertEqual(scene.context.completeTransitionCallCount, 1, "completeTransition must fire exactly once")
        XCTAssertEqual(scene.context.completeTransitionFlags, [false])
        // The teardown is complete and the cancel-recovery invariant holds.
        XCTAssertEqual(scene.detail.view.transform, .identity)
        XCTAssertEqual(scene.detail.view.frame, finalFrame)
        XCTAssertTrue(scene.detail.view.superview === scene.container)
        XCTAssertFalse(scene.source.isHidden)
        XCTAssertEqual(portalCount(in: scene.container), 0)
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertNil(scene.transition.currentDriver)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
        XCTAssertEqual(spy.didEndCount, 1)
        XCTAssertEqual(spy.lastResult, ZoomTransition.Result(isCompleted: false, wasInteractive: true, fallbackReason: nil))
    }

    // MARK: - S4: memory

    func test_memory_driverInteractionDriverAndPortalDeallocateAfterInteractiveTransition() {
        weak var weakInteractionDriver: ZoomInteractionDriver?
        weak var weakAnimationDriver: TransitionDriver?
        weak var weakTransition: ZoomTransition?
        weak var weakDetail: UIViewController?
        weak var weakPortal: PortalView?

        let spy = SpyDelegate()
        let exp = expectation(description: "memory didEnd")
        spy.didEndExpectation = exp

        autoreleasepool {
            let scene = makeInteractiveDismissScene(delegate: spy)
            weakInteractionDriver = scene.driver
            weakAnimationDriver = scene.animationDriver
            weakTransition = scene.transition
            weakDetail = scene.detail

            scene.start()
            weakPortal = scene.transition.activeTransition?.animationContext.portal
            XCTAssertNotNil(weakPortal, "a portal must exist mid-transition")

            scene.pan(.changed, translation: CGPoint(x: 0, y: 260))
            scene.pan(.ended, translation: CGPoint(x: 0, y: 260), velocity: CGPoint(x: 0, y: 1_600))
            waitForExpectations(timeout: 5)

            // Drop the only external holders; `detail` owns the transition (which owns the driver).
            scene.detail.view.removeFromSuperview()
            scene.window.isHidden = true
            scene.window.rootViewController = nil
        }

        XCTAssertNil(weakInteractionDriver, "interaction driver must deallocate with its transition")
        XCTAssertNil(weakAnimationDriver, "animation driver must deallocate after cleanup drops currentDriver")
        XCTAssertNil(weakTransition, "transition must deallocate with its view controller")
        XCTAssertNil(weakDetail, "destination view controller must deallocate")
        XCTAssertNil(weakPortal, "portal must deallocate after cleanup")
    }
}
