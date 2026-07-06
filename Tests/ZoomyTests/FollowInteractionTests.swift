import XCTest
import UIKit
import ZoomyCore
@testable import Zoomy

/// Driver-logic coverage for `ZoomInteractionDriver` (brief §8, "FollowInteractionTests"): that a
/// `.changed` sample maps the `FollowModel` output onto the portal and the (capped) transition
/// animator, that release routes to finish/cancel per `shouldComplete`, that a reversed-rebuild
/// grab remaps the transition fraction, and that the scroll-view / direction gate is honoured.
@MainActor
final class FollowInteractionTests: XCTestCase {

    private var savedAssertHandler: (@MainActor (String) -> Void)!

    override func setUp() {
        super.setUp()
        savedAssertHandler = ZoomyAssert.handler
    }

    override func tearDown() {
        ZoomyAssert.handler = savedAssertHandler
        super.tearDown()
    }

    // MARK: - .changed applies the follow model to the portal

    func test_changed_appliesFollowGeometryAndCappedFractionAndReportsProgress() {
        let scene = makeInteractiveDismissScene()
        scene.start()

        guard let active = scene.transition.activeTransition else {
            return XCTFail("startInteractiveTransition must stage an active transition")
        }
        let portal = active.animationContext.portal
        let seedCenter = portal.center
        let finalSize = active.animationContext.finalFrame.size

        // An oracle model built with the same seed the driver used.
        let oracle = FollowModel(containerSize: scene.container.bounds.size, initialCenter: seedCenter)
        let translation = CGPoint(x: 12, y: 180)
        let expectedProgress = oracle.progress(for: translation)
        let expectedScale = oracle.scale(forProgress: expectedProgress)
        let expectedCenter = oracle.center(for: translation)

        scene.pan(.changed, translation: translation)

        // Portal center follows the finger; portal size = finalSize · scale.
        XCTAssertEqual(portal.center.x, expectedCenter.x, accuracy: 0.5)
        XCTAssertEqual(portal.center.y, expectedCenter.y, accuracy: 0.5)
        XCTAssertEqual(portal.bounds.width, finalSize.width * expectedScale, accuracy: 0.5)
        XCTAssertEqual(portal.bounds.height, finalSize.height * expectedScale, accuracy: 0.5)

        // Live view counter-scales to the same factor.
        XCTAssertEqual(active.animationContext.zoomedView.transform.a, expectedScale, accuracy: 0.001)

        // Transition animator is scrubbed to the progress and capped at 0.995.
        XCTAssertEqual(active.transitionAnimator.fractionComplete, min(expectedProgress, 0.995), accuracy: 0.001)
        XCTAssertLessThanOrEqual(active.transitionAnimator.fractionComplete, 0.995)

        // updateInteractiveTransition(progress) was reported.
        XCTAssertEqual(scene.context.updateInteractiveCallCount, 1)
        XCTAssertEqual(scene.context.lastUpdateInteractivePercent ?? -1, expectedProgress, accuracy: 0.001)
    }

    func test_changed_progressIsClampedSoFractionNeverExceeds0995() {
        let scene = makeInteractiveDismissScene()
        scene.start()
        // A translation far beyond the span clamps progress to 1 → fraction capped at 0.995.
        scene.pan(.changed, translation: CGPoint(x: 0, y: 5_000))

        let fraction = scene.transition.activeTransition?.transitionAnimator.fractionComplete ?? -1
        XCTAssertEqual(fraction, 0.995, accuracy: 0.0001)
    }

    // MARK: - release → settle direction

    func test_release_downwardFlick_finishes() {
        let scene = makeInteractiveDismissScene()
        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 0, y: 120))
        scene.pan(.ended, translation: CGPoint(x: 0, y: 120), velocity: CGPoint(x: 0, y: 1_500))

        XCTAssertEqual(scene.context.finishInteractiveCallCount, 1, "a downward flick must finish")
        XCTAssertEqual(scene.context.cancelInteractiveCallCount, 0)
    }

    func test_release_upwardFlick_cancels() {
        let scene = makeInteractiveDismissScene()
        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 0, y: 120))
        scene.pan(.ended, translation: CGPoint(x: 0, y: 120), velocity: CGPoint(x: 0, y: -1_500))

        XCTAssertEqual(scene.context.cancelInteractiveCallCount, 1, "an upward flick must cancel")
        XCTAssertEqual(scene.context.finishInteractiveCallCount, 0)
    }

    func test_release_sidewaysFlick_finishes() {
        let scene = makeInteractiveDismissScene()
        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 260, y: 40))
        scene.pan(.ended, translation: CGPoint(x: 260, y: 40), velocity: CGPoint(x: 2_500, y: 0))

        XCTAssertEqual(scene.context.finishInteractiveCallCount, 1, "a sideways dismiss flick must finish")
        XCTAssertEqual(scene.context.cancelInteractiveCallCount, 0)
    }

    // MARK: - reversed-rebuild grab remaps the transition fraction (§4 rule 2)

    func test_regrabAfterCancelSettle_rebuildsTransitionAnimatorAndRemapsFraction() {
        let scene = makeInteractiveDismissScene()
        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 0, y: 160))

        let animatorBeforeGrab = scene.transition.activeTransition?.transitionAnimator

        // Release short/upward → cancel settle (transition animator runs reversed).
        scene.pan(.ended, translation: CGPoint(x: 0, y: 160), velocity: CGPoint(x: 0, y: -400))
        XCTAssertEqual(scene.transition.activeTransition?.transitionAnimator.isReversed, true)

        // Re-grab mid cancel-settle: a reversed animator must be rebuilt, not scrubbed.
        scene.pan(.began, translation: .zero)
        let animatorAfterGrab = scene.transition.activeTransition?.transitionAnimator
        XCTAssertFalse(animatorAfterGrab === animatorBeforeGrab,
                       "a reversed transition animator must be stopped and rebuilt on grab (never scrubbed)")
        XCTAssertEqual(animatorAfterGrab?.isReversed, false, "the rebuilt animator starts forward, paused at 0")

        // Follow again: the remapped fraction (base > 0) is strictly below the global progress.
        guard let active = scene.transition.activeTransition else { return XCTFail("still active") }
        let oracle = FollowModel(
            containerSize: scene.container.bounds.size,
            initialCenter: active.animationContext.portal.center
        )
        let translation = CGPoint(x: 0, y: 60)
        let localProgress = oracle.progress(for: translation)
        scene.pan(.changed, translation: translation)

        let fraction = active.transitionAnimator.fractionComplete
        XCTAssertGreaterThan(fraction, 0, "the rebuilt animator advances from its base")
        // remap(base + local·(1-base), base) == local, so the fraction tracks the *local* progress,
        // which is strictly less than the global progress it was remapped from.
        XCTAssertEqual(fraction, localProgress, accuracy: 0.05)
    }

    // MARK: - gestureRecognizerShouldBegin gate

    private func makeGesture(in view: UIView, translation: CGPoint) -> MockPanGestureRecognizer {
        let gesture = MockPanGestureRecognizer()
        gesture.mockView = view
        gesture.mockTranslation = translation
        return gesture
    }

    func test_shouldBegin_downwardWithScrollAtTop_isTrue() {
        let scene = makeInteractiveDismissScene()
        let scroll = UIScrollView(frame: scene.detail.view.bounds)
        scroll.contentOffset = .zero
        scene.detail.view.addSubview(scroll)

        let gesture = makeGesture(in: scene.detail.view, translation: CGPoint(x: 0, y: 20))
        XCTAssertTrue(scene.driver.gestureRecognizerShouldBegin(gesture))
    }

    func test_shouldBegin_downwardWithScrollNotAtTop_isFalse() {
        let scene = makeInteractiveDismissScene()
        let scroll = UIScrollView(frame: scene.detail.view.bounds)
        scroll.contentOffset = CGPoint(x: 0, y: 120)
        scene.detail.view.addSubview(scroll)

        let gesture = makeGesture(in: scene.detail.view, translation: CGPoint(x: 0, y: 20))
        XCTAssertFalse(scene.driver.gestureRecognizerShouldBegin(gesture),
                       "a scroll view scrolled below its top must own the drag")
    }

    func test_shouldBegin_noScrollView_downward_isTrue() {
        let scene = makeInteractiveDismissScene()
        let gesture = makeGesture(in: scene.detail.view, translation: CGPoint(x: 0, y: 20))
        XCTAssertTrue(scene.driver.gestureRecognizerShouldBegin(gesture))
    }

    func test_shouldBegin_upwardOrHorizontal_isFalse() {
        let scene = makeInteractiveDismissScene()
        let up = makeGesture(in: scene.detail.view, translation: CGPoint(x: 0, y: -20))
        let sideways = makeGesture(in: scene.detail.view, translation: CGPoint(x: 40, y: 5))
        XCTAssertFalse(scene.driver.gestureRecognizerShouldBegin(up), "an upward drag must not begin a dismiss")
        XCTAssertFalse(scene.driver.gestureRecognizerShouldBegin(sideways), "a horizontal-dominant drag must not begin")
    }

    func test_shouldBegin_whenAlreadyInteractive_isFalse() {
        let scene = makeInteractiveDismissScene()
        scene.start()
        scene.pan(.changed, translation: CGPoint(x: 0, y: 60)) // now .interactive
        let gesture = makeGesture(in: scene.detail.view, translation: CGPoint(x: 0, y: 20))
        XCTAssertFalse(scene.driver.gestureRecognizerShouldBegin(gesture),
                       "no second recognizer may begin while a follow is already in flight")
    }

    // MARK: - C1: the built-in pan dismiss must begin *before* `wantsInteractiveStart` is vended

    /// Regression gate for the chicken-and-egg deadlock (whole-branch review C1): the flag is only
    /// turned on when the adapter vends the driver, which happens *inside* the `dismiss()` that the
    /// gesture triggers. Gating begin on the flag would mean it can never be true in time. With the
    /// flag still `false` (the real pre-vend state), a downward-from-top drag must still begin.
    func test_shouldBegin_idleWithoutVendedFlag_beginsAnyway() {
        let scene = makeInteractiveDismissScene(presetInteractiveStart: false)
        XCTAssertFalse(scene.driver.wantsInteractiveStart, "precondition: flag is not yet vended")
        let gesture = makeGesture(in: scene.detail.view, translation: CGPoint(x: 0, y: 20))
        XCTAssertTrue(scene.driver.gestureRecognizerShouldBegin(gesture),
                      "a fresh downward-from-top drag must begin even before the vend sets the flag")
    }

    /// The other half of C1: even after begin, `handlePanBegan(.idle)` must trigger the dismissal
    /// (which is what makes the gesture active so the vend then sees `isGestureActive`). Before the
    /// fix its `guard wantsInteractiveStart` returned early, so `dismiss()` never fired.
    func test_began_idleWithoutVendedFlag_triggersDismissal() {
        let spy = DismissSpyViewController()
        let scene = makeInteractiveDismissScene(detail: spy, presetInteractiveStart: false)
        let gesture = MockPanGestureRecognizer()
        gesture.mockView = spy.view
        gesture.mockState = .began
        gesture.mockTranslation = CGPoint(x: 0, y: 8)

        scene.driver.handlePan(gesture)

        XCTAssertEqual(spy.dismissCallCount, 1,
                       "a gesture-initiated begin must trigger dismiss even before the flag is vended")
    }

    /// Regression guard (§5): a *programmatic* dismiss leaves the pan idle, so the adapter must still
    /// return `nil` (non-interactive) — the C1 fix must not turn every dismiss interactive.
    func test_programmaticDismiss_idlePan_adapterStaysNonInteractive() {
        let scene = makeInteractiveDismissScene(presetInteractiveStart: false)
        XCTAssertFalse(scene.driver.isGestureActive, "precondition: no gesture is driving")
        let animator = TransitionDriver(transition: scene.transition, phase: .disappearing, operation: .dismiss)
        let interactionController = scene.transition.modalAdapter.interactionControllerForDismissal(using: animator)
        XCTAssertNil(interactionController, "an idle-pan (programmatic) dismiss must stay non-interactive")
    }
}
