import XCTest
import UIKit
@testable import Zoomy

/// Regression gate for the nav-pop "returns to source" fix: on a real navigation pop the revealed
/// destination (which hosts the source view) is **not in the window yet** when the driver resolves
/// the source. Before the fix the source resolved as `.detached` and the pop fell back to a
/// cross-dissolve (shrink-to-center) instead of zooming back to the source cell — the modal dismiss
/// worked only because its presenter stays in the window (`shouldRemovePresentersView`).
///
/// The driver now seats the revealed view in the container *before* source resolution
/// (`seatRevealedPopDestination`), so the source has a window and the zoom runs.
///
/// The existing pop scenes (`makeInteractivePopScene`, `ZoomNavigationDelegateTests`) put the
/// revealed view in the window as the window's root, so they can't observe this — this scene keeps
/// it deliberately detached.
@MainActor
final class NavPopSourceResolutionTests: XCTestCase {

    private final class SpyDelegate: ZoomTransitionDelegate {
        var lastResult: ZoomTransition.Result?
        var didEndExpectation: XCTestExpectation?
        func zoomTransition(_ transition: ZoomTransition, didEnd context: ZoomTransition.Context,
                            result: ZoomTransition.Result) {
            lastResult = result
            didEndExpectation?.fulfill()
        }
    }

    func test_navPop_withDetachedRevealedView_zoomsToSourceInsteadOfFallingBack() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let container = UIView(frame: window.bounds)
        window.addSubview(container)

        // The revealed predecessor (the grid) hosts the source, but its view is deliberately NOT in
        // the window/container — exactly the state a real nav pop starts in.
        let predecessor = UIViewController()
        predecessor.view.frame = window.bounds
        let source = UIView(frame: CGRect(x: 80, y: 320, width: 160, height: 160))
        source.backgroundColor = .systemRed
        source.layer.cornerRadius = 12
        predecessor.view.addSubview(source)

        // The departing detail sits in the container (it was on screen).
        let detail = UIViewController()
        detail.view.backgroundColor = .systemBlue
        detail.view.frame = container.bounds
        container.addSubview(detail.view)

        let spy = SpyDelegate()
        let transition = ZoomTransition { _ in source }
        transition.delegate = spy
        detail.zoomTransition = transition
        transition.pushPredecessor = predecessor

        let context = MockTransitionContext(
            containerView: container,
            fromViewController: detail,      // departing
            toViewController: predecessor,   // revealed (starts detached)
            fromView: detail.view,
            toView: predecessor.view
        )

        // Precondition: the source has no window before the transition (would be `.detached`).
        XCTAssertNil(source.window)

        let exp = expectation(description: "pop didEnd")
        spy.didEndExpectation = exp
        let driver = TransitionDriver(transition: transition, phase: .disappearing, operation: .pop)
        driver.animateTransition(using: context)

        // Synchronous prepare already ran: the fix seated the revealed view, so the source now has a
        // window and the *zoom* strategy hid it. A cross-dissolve fallback would do neither.
        XCTAssertNotNil(source.window, "the revealed view must be seated so the source resolves")
        XCTAssertTrue(source.isHidden, "the zoom path hides the source; the cross-dissolve fallback does not")

        waitForExpectations(timeout: 5)

        XCTAssertEqual(context.completeTransitionCallCount, 1)
        XCTAssertEqual(context.completeTransitionFlags, [true])
        XCTAssertNil(spy.lastResult?.fallbackReason,
                     "a nav pop with a resolvable source must zoom home, not fall back to a cross-dissolve")
        XCTAssertFalse(source.isHidden, "source must be unhidden after completion")
        XCTAssertEqual(transition.stateMachine.state, .idle)
        XCTAssertNil(transition.activeTransition)
    }

    /// Regression gate for the "weird pop content" fix: UIKit returns `.zero` from
    /// `finalFrame(for:)` for the *departing* controller of a pop ("won't be visible at the end").
    /// The driver used that as the content-scale reference, so the portal shrank to the source cell
    /// but the live view stayed full-size pinned to the top-left (scale computed as 1, center `.zero`).
    /// The driver now falls back to the departing view's current frame, so the content scales with
    /// the portal. Asserted on the staged `animationContext.finalFrame` (captured synchronously
    /// mid-flight, before the barrier completes).
    func test_navPop_withEmptyFinalFrameFromUIKit_usesDepartingFrameForContentScale() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let container = UIView(frame: window.bounds)
        window.addSubview(container)

        let predecessor = UIViewController()
        predecessor.view.frame = window.bounds
        let source = UIView(frame: CGRect(x: 80, y: 320, width: 160, height: 160))
        source.backgroundColor = .systemRed
        predecessor.view.addSubview(source)

        let detail = UIViewController()
        detail.view.backgroundColor = .systemBlue
        detail.view.frame = container.bounds
        container.addSubview(detail.view)

        let transition = ZoomTransition { _ in source }
        detail.zoomTransition = transition
        transition.pushPredecessor = predecessor

        let context = MockTransitionContext(
            containerView: container,
            fromViewController: detail,
            toViewController: predecessor,
            fromView: detail.view,
            toView: predecessor.view
        )
        // Reproduce UIKit's real pop behavior: the departing controller's final frame is empty.
        context.finalFrameOverrides[ObjectIdentifier(detail)] = .zero

        let driver = TransitionDriver(transition: transition, phase: .disappearing, operation: .pop)
        driver.animateTransition(using: context)

        // Synchronously staged: the content-scale reference must be the departing view's full frame,
        // never the empty rect UIKit reported (which would leave the live view full-size).
        let staged = transition.activeTransition?.animationContext.finalFrame
        XCTAssertEqual(staged, container.bounds,
                       "an empty UIKit finalFrame must fall back to the departing view's current frame")
        XCTAssertNotEqual(staged, .zero)

        // Let it settle so the transition tears down cleanly (no dangling active transition).
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settle.fulfill() }
        waitForExpectations(timeout: 5)
        XCTAssertEqual(context.completeTransitionCallCount, 1)
        XCTAssertNil(transition.activeTransition)
    }
}
