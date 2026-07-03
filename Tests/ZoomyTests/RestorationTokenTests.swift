import XCTest
import UIKit
@testable import Zoomy

@MainActor
final class RestorationTokenTests: XCTestCase {

    // MARK: - Ordering / idempotence

    func test_restore_runsRecordedClosuresInReverseOrder() {
        let token = RestorationToken()
        var order: [Int] = []
        token.record { order.append(1) }
        token.record { order.append(2) }
        token.record { order.append(3) }

        token.restore()

        XCTAssertEqual(order, [3, 2, 1])
    }

    func test_restore_isIdempotent() {
        let token = RestorationToken()
        var callCount = 0
        token.record { callCount += 1 }

        token.restore()
        token.restore()
        token.restore()

        XCTAssertEqual(callCount, 1)
    }

    // MARK: - deinit backstop

    func test_deinit_actsAsBackstopWhenRestoreWasNeverCalled() {
        var callCount = 0
        var token: RestorationToken? = RestorationToken()
        token!.record { callCount += 1 }

        token = nil // never called restore() explicitly

        XCTAssertEqual(callCount, 1)
    }

    func test_deinit_isANoOpIfRestoreAlreadyRan() {
        var callCount = 0
        var token: RestorationToken? = RestorationToken()
        token!.record { callCount += 1 }
        token!.restore()
        XCTAssertEqual(callCount, 1)

        token = nil

        XCTAssertEqual(callCount, 1, "deinit must not re-run an already-restored token")
    }

    // MARK: - Weak capture

    func test_recordedClosures_captureViewsWeaklyAndDoNotCrashAfterDeallocation() {
        let token = RestorationToken()
        var view: UIView? = UIView()
        weak var probe = view
        token.recordHide(of: view!)

        view = nil // drop the only strong reference before restore() ever runs

        // The probe going nil *while the token still holds its recorded closure* proves the
        // closure's capture really is weak — a strong capture would keep the view alive here
        // and this test would fail, rather than silently passing on "didn't crash" alone.
        XCTAssertNil(probe, "recordHide must capture the view weakly, not keep it alive")

        token.restore() // and restoring against the deallocated view must not crash
    }

    // MARK: - Convenience recorders restore the *original* captured value

    func test_recordHide_restoresOriginalIsHiddenValue() {
        let token = RestorationToken()
        let view = UIView()
        view.isHidden = false

        token.recordHide(of: view)
        view.isHidden = true

        token.restore()

        XCTAssertFalse(view.isHidden)
    }

    func test_recordAlpha_restoresOriginalAlphaValue() {
        let token = RestorationToken()
        let view = UIView()
        view.alpha = 0.4

        token.recordAlpha(of: view)
        view.alpha = 1.0

        token.restore()

        XCTAssertEqual(view.alpha, 0.4, accuracy: 0.0001)
    }

    func test_recordScrollLock_restoresOriginalIsScrollEnabledValue() {
        let token = RestorationToken()
        let scrollView = UIScrollView()
        scrollView.isScrollEnabled = true

        token.recordScrollLock(of: scrollView)
        scrollView.isScrollEnabled = false

        token.restore()

        XCTAssertTrue(scrollView.isScrollEnabled)
    }

    func test_recordAdditionalSafeAreaInsets_restoresOriginalInsetsValue() {
        let token = RestorationToken()
        let viewController = UIViewController()
        let original = UIEdgeInsets(top: 1, left: 2, bottom: 3, right: 4)
        viewController.additionalSafeAreaInsets = original

        token.recordAdditionalSafeAreaInsets(of: viewController)
        viewController.additionalSafeAreaInsets = .zero

        token.restore()

        XCTAssertEqual(viewController.additionalSafeAreaInsets, original)
    }

    func test_recordTransform_restoresOriginalTransformValue() {
        let token = RestorationToken()
        let view = UIView()
        let original = CGAffineTransform(scaleX: 0.5, y: 0.5)
        view.transform = original

        token.recordTransform(of: view)
        view.transform = .identity

        token.restore()

        XCTAssertEqual(view.transform, original)
    }

    func test_recordAdditionalSafeAreaInsets_capturesWeaklyAndDoesNotCrashAfterDeallocation() {
        let token = RestorationToken()
        var viewController: UIViewController? = UIViewController()
        weak var probe = viewController
        token.recordAdditionalSafeAreaInsets(of: viewController!)

        viewController = nil // drop the only strong reference before restore() ever runs

        // See test_recordedClosures_captureViewsWeakly...: the probe must already be nil while
        // the token still holds the closure, proving the capture is weak (a strong capture
        // would keep the VC alive and fail here).
        XCTAssertNil(probe, "recordAdditionalSafeAreaInsets must capture the VC weakly, not keep it alive")

        token.restore() // and restoring against the deallocated VC must not crash
    }
}
