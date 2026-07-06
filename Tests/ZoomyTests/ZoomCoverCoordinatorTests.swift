import XCTest
import SwiftUI
import UIKit
@testable import Zoomy
import ZoomyCore

@MainActor
final class ZoomCoverCoordinatorTests: XCTestCase {

    private struct StubItem: Identifiable, Equatable { let id: String }

    private func makeCoordinator(
        recording actions: @escaping (ZoomCoverAction) -> Void
    ) -> ZoomCoverCoordinator<StubItem, Text> {
        let coordinator = ZoomCoverCoordinator<StubItem, Text>(
            configuration: .default,
            content: { Text($0.id) }
        )
        coordinator.performer = actions   // replace the real UIKit performer with a recorder
        return coordinator
    }

    private func didEnd(_ coordinator: ZoomCoverCoordinator<StubItem, Text>, dismiss: Bool, completed: Bool) {
        let context = ZoomTransition.Context(
            zoomedViewController: nil,
            sourceViewController: nil,
            phase: .disappearing,
            operation: dismiss ? .dismiss : .present,
            isInteractive: true
        )
        let result = ZoomTransition.Result(isCompleted: completed, wasInteractive: true, fallbackReason: nil)
        let dummy = ZoomTransition(configuration: .default) { _ in nil }
        coordinator.zoomTransition(dummy, didEnd: context, result: result)
    }

    // MARK: - reconcile → action + phase advancement

    func test_reconcile_fromIdle_recordsPresentAndEntersPresenting() {
        var recorded: [ZoomCoverAction] = []
        let coordinator = makeCoordinator(recording: { recorded.append($0) })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)

        XCTAssertEqual(recorded, [.present(AnyHashable("a"))])
        XCTAssertEqual(coordinator.phase, .presenting(AnyHashable("a")))
    }

    func test_advanceAfterPresent_settlesToPresented_noExtraAction() {
        var recorded: [ZoomCoverAction] = []
        let coordinator = makeCoordinator(recording: { recorded.append($0) })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)   // .presenting(a), records .present
        coordinator.advance()                      // present completed → .presented(a), re-reconcile

        XCTAssertEqual(coordinator.phase, .presented(AnyHashable("a")))
        XCTAssertEqual(recorded, [.present(AnyHashable("a"))], "same item still desired → no dismiss")
    }

    func test_deferredDismiss_appliedOnPresentCompletion() {
        var recorded: [ZoomCoverAction] = []
        let coordinator = makeCoordinator(recording: { recorded.append($0) })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)   // .presenting(a)
        backing = nil                              // user dismisses mid-present-animation
        coordinator.reconcile(desired: backing)   // .presenting → deferred .none
        XCTAssertEqual(recorded, [.present(AnyHashable("a"))])

        coordinator.advance()                      // present completes → .presented → re-reconcile → dismiss
        XCTAssertEqual(recorded, [.present(AnyHashable("a")), .dismiss])
        XCTAssertEqual(coordinator.phase, .dismissing)
    }

    // MARK: - didEnd: engine-initiated dismiss syncs the binding

    func test_didEnd_interactiveCompletedDismiss_whilePresented_clearsBinding() {
        let coordinator = makeCoordinator(recording: { _ in })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)   // .presenting(a)
        coordinator.advance()                      // .presented(a)

        didEnd(coordinator, dismiss: true, completed: true)

        XCTAssertNil(backing, "an engine-initiated dismiss must sync the binding to nil")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_didEnd_cancelledDrag_leavesBindingAndPhase() {
        let coordinator = makeCoordinator(recording: { _ in })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)
        coordinator.advance()                      // .presented(a)

        didEnd(coordinator, dismiss: true, completed: false)   // cancelled drag

        XCTAssertEqual(backing, StubItem(id: "a"))
        XCTAssertEqual(coordinator.phase, .presented(AnyHashable("a")))
    }

    func test_didEnd_present_ignored() {
        let coordinator = makeCoordinator(recording: { _ in })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)
        coordinator.advance()                      // .presented(a)

        didEnd(coordinator, dismiss: false, completed: true)   // present didEnd

        XCTAssertEqual(backing, StubItem(id: "a"))
        XCTAssertEqual(coordinator.phase, .presented(AnyHashable("a")))
    }

    // MARK: - topmost presenter walk

    func test_topmost_returnsDeepestNonDismissingPresented() {
        final class Fake: UIViewController {
            var stub: UIViewController?
            override var presentedViewController: UIViewController? { stub }
        }
        let root = Fake(), mid = Fake()
        let leaf = UIViewController()
        root.stub = mid
        mid.stub = leaf
        XCTAssertTrue(ZoomCoverPresenter.topmost(from: root) === leaf)
    }
}
