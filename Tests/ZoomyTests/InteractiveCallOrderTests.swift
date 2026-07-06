import XCTest
import UIKit
import ZoomyCore
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

    // MARK: - S3b: grab a *reversed* (cancel) settle → rebuild → complete

    /// The hardest path (§4 rule 2): the first release cancels, so the transition animator runs
    /// *reversed*; a mid-settle grab must stop-and-rebuild it (never scrub a reversed animator), and
    /// the rebuilt forward animator must then settle to completion with exactly one
    /// `completeTransition`. S3 only exercised the scrub-safe forward-freeze branch — this drives the
    /// `if isReversed` branch end-to-end.
    func test_grabDuringCancelSettle_rebuildsReversedAnimatorThenCompletesExactlyOnce() {
        let spy = SpyDelegate()
        let exp = expectation(description: "reverse-rebuild then complete didEnd")
        spy.didEndExpectation = exp
        let scene = makeInteractiveDismissScene(delegate: spy)

        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 0, y: 150))
        let animatorBeforeGrab = scene.transition.activeTransition?.transitionAnimator

        // 1st release: upward → cancel settle (transition animator runs reversed).
        scene.pan(.ended, translation: CGPoint(x: 0, y: 150), velocity: CGPoint(x: 0, y: -600))
        XCTAssertEqual(scene.transition.stateMachine.state, .settling(.zoomOut, toCompleted: false))
        XCTAssertEqual(scene.transition.activeTransition?.transitionAnimator.isReversed, true,
                       "a cancel settle must run the transition animator reversed")

        // Re-grab mid cancel-settle → the reversed animator is stopped and rebuilt (not scrubbed).
        scene.pan(.began, translation: .zero)
        XCTAssertEqual(scene.transition.stateMachine.state, .interactive(.zoomOut))
        let animatorAfterGrab = scene.transition.activeTransition?.transitionAnimator
        XCTAssertFalse(animatorAfterGrab === animatorBeforeGrab,
                       "the reversed transition animator must be rebuilt on grab, never scrubbed")
        XCTAssertEqual(animatorAfterGrab?.isReversed, false, "the rebuilt animator starts forward, paused")

        scene.pan(.changed, translation: CGPoint(x: 0, y: 120))
        // 2nd release: downward flick → complete.
        scene.pan(.ended, translation: CGPoint(x: 0, y: 120), velocity: CGPoint(x: 0, y: 1_600))

        waitForExpectations(timeout: 5)

        // Exactly one completeTransition, in the final (complete) direction — no double-fire from the
        // stopped reversed animator or the frozen first-settle spring.
        XCTAssertEqual(scene.context.completeTransitionCallCount, 1, "completeTransition must fire exactly once")
        XCTAssertEqual(scene.context.completeTransitionFlags, [true])
        // Both settle directions were driven: one cancel then one finish.
        XCTAssertEqual(scene.context.cancelInteractiveCallCount, 1)
        XCTAssertEqual(scene.context.finishInteractiveCallCount, 1)
        // Completed dismiss → source revealed, no scaffolding left, teardown complete.
        XCTAssertFalse(scene.source.isHidden)
        XCTAssertEqual(portalCount(in: scene.container), 0)
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertNil(scene.transition.currentDriver)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
        XCTAssertEqual(spy.didEndCount, 1)
        XCTAssertEqual(spy.lastResult, ZoomTransition.Result(isCompleted: true, wasInteractive: true, fallbackReason: nil))
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

    // MARK: - I2: interactive → fallback stages exactly once

    /// Regression gate for the whole-branch review I2: an interactive start whose source can't be
    /// resolved falls back, and before the fix that ran `makeStagedContext` twice — reporting
    /// `willBegin` twice (contract: once per phase) and re-invoking the provider. The fallback must
    /// now run on the single staged context.
    func test_interactiveStartWithUnresolvedSource_reportsWillBeginExactlyOnce() {
        let spy = SpyDelegate()
        let exp = expectation(description: "interactive fallback didEnd")
        spy.didEndExpectation = exp
        let scene = makeInteractiveDismissScene(resolvesSource: false, delegate: spy)

        scene.start()
        waitForExpectations(timeout: 5)

        XCTAssertEqual(spy.willBeginCount, 1, "willBegin must fire exactly once on the interactive→fallback path")
        XCTAssertEqual(scene.context.completeTransitionCallCount, 1)
        XCTAssertEqual(scene.context.completeTransitionFlags, [true])
        XCTAssertEqual(portalCount(in: scene.container), 0)
        XCTAssertEqual(spy.didEndCount, 1)
        XCTAssertEqual(spy.lastResult?.fallbackReason, .sourceUnresolved)
        XCTAssertNil(scene.transition.activeTransition)
        XCTAssertEqual(scene.transition.stateMachine.state, .idle)
    }

    /// The dimming-leak half of I2 (the nav/pop path owns its own dimming view): the double-staging
    /// installed a second nav dimming view that overwrote `navigationOwnedDimmingView`, so cleanup
    /// removed only the second and the first leaked into the container as a permanent dark overlay.
    /// With single staging, no dimming view survives completion.
    func test_interactivePopFallback_leavesNoDimmingViewInContainer() {
        let spy = SpyDelegate()
        let exp = expectation(description: "interactive pop fallback didEnd")
        spy.didEndExpectation = exp
        let scene = makeInteractivePopScene(resolvesSource: false, delegate: spy)
        let dimmingCGColor = scene.transition.configuration.dimmingColor?.cgColor

        scene.start()
        waitForExpectations(timeout: 5)

        XCTAssertEqual(spy.willBeginCount, 1, "willBegin must fire exactly once")
        XCTAssertEqual(scene.context.completeTransitionCallCount, 1)
        let leakedDimming = scene.container.subviews.filter { $0.backgroundColor?.cgColor == dimmingCGColor }
        XCTAssertEqual(leakedDimming.count, 0, "the interactive→fallback path must not leak a nav dimming view")
        XCTAssertEqual(portalCount(in: scene.container), 0)
    }
}
