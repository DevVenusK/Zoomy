import XCTest
import ZoomyCore

final class ZoomCoverReducerTests: XCTestCase {

    private let a = AnyHashable("a")
    private let b = AnyHashable("b")

    // MARK: - next(desired:phase:) — exhaustive 8-cell decision table

    func test_next_someIdle_presents() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: a, phase: .idle), .present(a))
    }

    func test_next_noneIdle_none() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: nil, phase: .idle), .none)
    }

    func test_next_somePresenting_defersNone() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: a, phase: .presenting(a)), .none)
    }

    func test_next_nonePresenting_defersNone() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: nil, phase: .presenting(a)), .none)
    }

    func test_next_nonePresented_dismisses() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: nil, phase: .presented(a)), .dismiss)
    }

    func test_next_sameIdPresented_none() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: a, phase: .presented(a)), .none)
    }

    func test_next_differentIdPresented_dismisses() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: b, phase: .presented(a)), .dismiss)
    }

    func test_next_someDismissing_defersNone() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: a, phase: .dismissing), .none)
    }

    func test_next_noneDismissing_defersNone() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: nil, phase: .dismissing), .none)
    }

    // MARK: - advanced(_:) — phase after an animation completes

    func test_advanced_presenting_becomesPresented() {
        XCTAssertEqual(ZoomCoverReducer.advanced(.presenting(a)), .presented(a))
    }

    func test_advanced_dismissing_becomesIdle() {
        XCTAssertEqual(ZoomCoverReducer.advanced(.dismissing), .idle)
    }

    func test_advanced_idleAndPresented_unchanged() {
        XCTAssertEqual(ZoomCoverReducer.advanced(.idle), .idle)
        XCTAssertEqual(ZoomCoverReducer.advanced(.presented(a)), .presented(a))
    }

    // MARK: - shouldSyncOnDidEnd(...) — engine-initiated dismiss detection

    func test_shouldSync_completedDismissWhilePresented_true() {
        XCTAssertTrue(ZoomCoverReducer.shouldSyncOnDidEnd(isDismiss: true, isCompleted: true, isPresentedPhase: true))
    }

    func test_shouldSync_cancelledDismiss_false() {
        XCTAssertFalse(ZoomCoverReducer.shouldSyncOnDidEnd(isDismiss: true, isCompleted: false, isPresentedPhase: true))
    }

    func test_shouldSync_present_false() {
        XCTAssertFalse(ZoomCoverReducer.shouldSyncOnDidEnd(isDismiss: false, isCompleted: true, isPresentedPhase: true))
    }

    func test_shouldSync_notPresentedPhase_false() {
        XCTAssertFalse(ZoomCoverReducer.shouldSyncOnDidEnd(isDismiss: true, isCompleted: true, isPresentedPhase: false))
    }
}
