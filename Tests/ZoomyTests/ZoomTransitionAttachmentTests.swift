import XCTest
import UIKit
@testable import Zoomy

@MainActor
final class ZoomTransitionAttachmentTests: XCTestCase {

    private var previousHandler: (@MainActor (String) -> Void)!

    override func setUp() {
        super.setUp()
        previousHandler = ZoomyAssert.handler
    }

    override func tearDown() {
        ZoomyAssert.handler = previousHandler
        super.tearDown()
    }

    private func makeTransition() -> ZoomTransition {
        ZoomTransition(sourceViewProvider: { _ in nil })
    }

    // MARK: - Getter

    func test_getter_returnsTheAssignedTransition() {
        let vc = UIViewController()
        let transition = makeTransition()

        vc.zoomTransition = transition

        XCTAssertTrue(vc.zoomTransition === transition)
    }

    func test_getter_returnsNilBeforeAnyAssignment() {
        let vc = UIViewController()
        XCTAssertNil(vc.zoomTransition)
    }

    // MARK: - Install

    func test_setter_installsCustomStyleAndAdapterAsTransitioningDelegate() {
        let vc = UIViewController()
        let transition = makeTransition()

        vc.zoomTransition = transition

        XCTAssertEqual(vc.modalPresentationStyle, .custom)
        XCTAssertTrue(vc.transitioningDelegate === transition.modalAdapter)
        XCTAssertTrue(transition.attachedViewController === vc)
    }

    // MARK: - Snapshot/restore

    func test_nilAssignment_restoresOverFullScreen_notTheFullScreenConstant() {
        let vc = UIViewController()
        vc.modalPresentationStyle = .overFullScreen
        let transition = makeTransition()

        vc.zoomTransition = transition
        XCTAssertEqual(vc.modalPresentationStyle, .custom)

        vc.zoomTransition = nil

        XCTAssertEqual(vc.modalPresentationStyle, .overFullScreen)
        XCTAssertNotEqual(vc.modalPresentationStyle, .fullScreen)
    }

    func test_nilAssignment_restoresOriginalTransitioningDelegate() {
        final class OriginalDelegate: NSObject, UIViewControllerTransitioningDelegate {}

        let vc = UIViewController()
        let original = OriginalDelegate()
        vc.transitioningDelegate = original
        let transition = makeTransition()

        vc.zoomTransition = transition
        XCTAssertTrue(vc.transitioningDelegate === transition.modalAdapter)

        vc.zoomTransition = nil

        XCTAssertTrue(vc.transitioningDelegate === original)
    }

    func test_nilAssignment_clearsGetterAndAttachedViewController() {
        let vc = UIViewController()
        let transition = makeTransition()

        vc.zoomTransition = transition
        vc.zoomTransition = nil

        XCTAssertNil(vc.zoomTransition)
        XCTAssertNil(transition.attachedViewController)
    }

    func test_nilAssignment_doesNotTouchAForeignTransitioningDelegateInstalledAfterward() {
        final class ForeignDelegate: NSObject, UIViewControllerTransitioningDelegate {}

        let vc = UIViewController()
        let transition = makeTransition()
        vc.zoomTransition = transition

        // The app reassigns transitioningDelegate to something else after attaching Zoomy.
        let foreign = ForeignDelegate()
        vc.transitioningDelegate = foreign

        vc.zoomTransition = nil

        // Because transitioningDelegate no longer === our adapter, the setter must leave it
        // (and, by extension, the original snapshot) alone.
        XCTAssertTrue(vc.transitioningDelegate === foreign)
        XCTAssertNil(vc.zoomTransition)
        XCTAssertNil(transition.attachedViewController)
    }

    // MARK: - Double attachment

    func test_attachingASharedInstanceToASecondViewController_rejectsAndCallsAssertHandler() {
        let vc1 = UIViewController()
        let vc2 = UIViewController()
        let transition = makeTransition()
        vc1.zoomTransition = transition

        var messages: [String] = []
        ZoomyAssert.handler = { messages.append($0) }

        vc2.zoomTransition = transition

        XCTAssertEqual(messages.count, 1)
        XCTAssertNil(vc2.zoomTransition, "assignment must be rejected")
        XCTAssertTrue(vc1.zoomTransition === transition, "the original attachment must be untouched")
        XCTAssertTrue(transition.attachedViewController === vc1)
    }

    func test_reassigningTheSameInstanceToTheSameViewController_isANoOpNotARejection() {
        let vc = UIViewController()
        let transition = makeTransition()
        vc.zoomTransition = transition

        var messages: [String] = []
        ZoomyAssert.handler = { messages.append($0) }

        vc.zoomTransition = transition

        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(vc.zoomTransition === transition)
    }

    // MARK: - present-after-assignment precondition

    /// Driving a real, full `present(animated:completion:)` round trip to completion isn't
    /// reliable in a bare SPM test bundle (no hosting app / scene running the real presentation
    /// lifecycle) — confirmed by an earlier version of this test timing out waiting for the
    /// completion handler. Overriding the read-only `presentingViewController` getter exercises
    /// the exact same setter code path (`presentingViewController == nil` becomes `false`)
    /// without depending on that lifecycle.
    private final class PresentedViewController: UIViewController {
        private let fakePresenter = UIViewController()
        override var presentingViewController: UIViewController? { fakePresenter }
    }

    func test_assigningAfterPresentation_callsAssertHandler() {
        let vc = PresentedViewController()
        XCTAssertNotNil(vc.presentingViewController)

        var messages: [String] = []
        ZoomyAssert.handler = { messages.append($0) }

        vc.zoomTransition = makeTransition()

        XCTAssertEqual(messages.count, 1)
    }

    func test_assigningBeforePresentation_doesNotCallAssertHandler() {
        let vc = UIViewController()
        XCTAssertNil(vc.presentingViewController)

        var messages: [String] = []
        ZoomyAssert.handler = { messages.append($0) }

        vc.zoomTransition = makeTransition()

        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - Lifetime

    func test_associatedRetain_transitionLifetimeMatchesViewControllerLifetime() {
        weak var weakTransition: ZoomTransition?
        weak var weakViewController: UIViewController?

        func attachAndDropStrongReferences() {
            let vc = UIViewController()
            let transition = ZoomTransition(sourceViewProvider: { _ in nil })
            vc.zoomTransition = transition
            weakViewController = vc
            weakTransition = transition
        }

        attachAndDropStrongReferences()

        XCTAssertNil(weakViewController, "the view controller must not have leaked")
        XCTAssertNil(weakTransition, "the transition must be deallocated alongside its view controller")
    }

    // MARK: - reportWillBegin / reportDidEnd forward to the delegate

    private final class RecordingDelegate: ZoomTransitionDelegate {
        var willBeginContext: ZoomTransition.Context?
        var didEndContext: ZoomTransition.Context?
        var didEndResult: ZoomTransition.Result?

        func zoomTransition(_ transition: ZoomTransition, willBegin context: ZoomTransition.Context) {
            willBeginContext = context
        }

        func zoomTransition(_ transition: ZoomTransition, didEnd context: ZoomTransition.Context,
                            result: ZoomTransition.Result) {
            didEndContext = context
            didEndResult = result
        }
    }

    private func makeContext(phase: ZoomTransition.Phase, operation: ZoomTransition.Operation) -> ZoomTransition.Context {
        ZoomTransition.Context(
            zoomedViewController: nil,
            sourceViewController: nil,
            phase: phase,
            operation: operation,
            isInteractive: false
        )
    }

    func test_reportWillBegin_forwardsContextToDelegate() {
        let transition = makeTransition()
        let delegate = RecordingDelegate()
        transition.delegate = delegate

        let context = makeContext(phase: .appearing, operation: .present)
        transition.reportWillBegin(context)

        XCTAssertEqual(delegate.willBeginContext?.phase, .appearing)
        XCTAssertEqual(delegate.willBeginContext?.operation, .present)
    }

    func test_reportDidEnd_forwardsContextAndResultToDelegate() {
        let transition = makeTransition()
        let delegate = RecordingDelegate()
        transition.delegate = delegate

        let context = makeContext(phase: .disappearing, operation: .dismiss)
        let result = ZoomTransition.Result(isCompleted: false, wasInteractive: false, fallbackReason: .sourceUnresolved)
        transition.reportDidEnd(context, result: result)

        XCTAssertEqual(delegate.didEndContext?.phase, .disappearing)
        XCTAssertEqual(delegate.didEndContext?.operation, .dismiss)
        XCTAssertEqual(delegate.didEndResult, result)
    }

    func test_reportDidEnd_withNoFallbackReason_stillForwardsToDelegate() {
        let transition = makeTransition()
        let delegate = RecordingDelegate()
        transition.delegate = delegate

        let context = makeContext(phase: .disappearing, operation: .pop)
        let result = ZoomTransition.Result(isCompleted: true, wasInteractive: false, fallbackReason: nil)
        transition.reportDidEnd(context, result: result)

        XCTAssertEqual(delegate.didEndResult, result)
    }

    func test_reportWillBegin_withNoDelegateSet_doesNotCrash() {
        let transition = makeTransition()
        transition.reportWillBegin(makeContext(phase: .appearing, operation: .push))
        // No assertion beyond "did not crash" — delegate is nil by default.
    }
}
