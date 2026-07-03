import XCTest
import CoreGraphics
@testable import Zoomy

final class TransitionStateMachineTests: XCTestCase {

    // MARK: - Table-driven exhaustive transitions (spec §1 table, one test per row)

    func test_idle_beginNonInteractive_transitionsToAnimating() {
        var sm = TransitionStateMachine()
        let effects = sm.handle(.begin(.zoomIn, interactive: false))
        XCTAssertEqual(sm.state, .animating(.zoomIn))
        XCTAssertEqual(effects, [.startAnimators])
    }

    func test_idle_beginInteractive_transitionsToInteractive() {
        var sm = TransitionStateMachine()
        let effects = sm.handle(.begin(.zoomOut, interactive: true))
        XCTAssertEqual(sm.state, .interactive(.zoomOut))
        XCTAssertEqual(effects, [.startPausedForGesture])
    }

    func test_animating_grab_transitionsToInteractive() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: false))
        let effects = sm.handle(.grab)
        XCTAssertEqual(sm.state, .interactive(.zoomIn))
        XCTAssertEqual(effects, [.freezeGeometryAndPauseTransition])
    }

    func test_animating_allAnimatorsFinished_transitionsToIdle() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: false))
        let effects = sm.handle(.allAnimatorsFinished)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(effects, [.cleanupAndComplete(completed: true)])
    }

    func test_interactive_update_staysInteractiveAndAppliesFollow() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: true))
        let effects = sm.handle(.update(0.3))
        XCTAssertEqual(sm.state, .interactive(.zoomIn))
        XCTAssertEqual(effects, [.applyFollow(0.3)])
    }

    func test_interactive_release_transitionsToSettling() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomOut, interactive: true))
        let effects = sm.handle(.release(toCompleted: true))
        XCTAssertEqual(sm.state, .settling(.zoomOut, toCompleted: true))
        XCTAssertEqual(effects, [.settle(toCompleted: true)])
    }

    func test_settling_grab_transitionsToInteractive() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: true))
        _ = sm.handle(.release(toCompleted: false))
        let effects = sm.handle(.grab)
        XCTAssertEqual(sm.state, .interactive(.zoomIn))
        XCTAssertEqual(effects, [.freezeGeometryAndPauseTransition])
    }

    func test_settling_allAnimatorsFinished_transitionsToIdleWithStoredCompletion() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: true))
        _ = sm.handle(.release(toCompleted: false))
        let effects = sm.handle(.allAnimatorsFinished)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(effects, [.cleanupAndComplete(completed: false)])
    }

    func test_animating_forceFinish_fastForwardsAndCompletesAsTrue() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: false))
        let effects = sm.handle(.forceFinish(.sizeChange))
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(effects, [.fastForwardAll(toCompleted: true), .cleanupAndComplete(completed: true)])
    }

    func test_interactive_forceFinish_usesLastProgressAboveHalfToComplete() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: true))
        _ = sm.handle(.update(0.6))
        let effects = sm.handle(.forceFinish(.abandoned))
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(effects, [.fastForwardAll(toCompleted: true), .cleanupAndComplete(completed: true)])
    }

    func test_interactive_forceFinish_usesLastProgressBelowHalfToCancel() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: true))
        _ = sm.handle(.update(0.4))
        let effects = sm.handle(.forceFinish(.sceneBackground))
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(effects, [.fastForwardAll(toCompleted: false), .cleanupAndComplete(completed: false)])
    }

    func test_interactive_forceFinish_defaultLastProgressZeroIsBelowHalf() {
        // No update() ever called: lastProgress defaults to 0, which is not > 0.5.
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: true))
        let effects = sm.handle(.forceFinish(.abandoned))
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(effects, [.fastForwardAll(toCompleted: false), .cleanupAndComplete(completed: false)])
    }

    func test_settling_forceFinish_usesStoredToCompletedTrue() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomOut, interactive: true))
        _ = sm.handle(.release(toCompleted: true))
        let effects = sm.handle(.forceFinish(.sizeChange))
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(effects, [.fastForwardAll(toCompleted: true), .cleanupAndComplete(completed: true)])
    }

    func test_settling_forceFinish_usesStoredToCompletedFalse() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomOut, interactive: true))
        _ = sm.handle(.release(toCompleted: false))
        let effects = sm.handle(.forceFinish(.sceneBackground))
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(effects, [.fastForwardAll(toCompleted: false), .cleanupAndComplete(completed: false)])
    }

    func test_begin_isRejected_fromAnimating() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: false))
        let effects = sm.handle(.begin(.zoomOut, interactive: true))
        XCTAssertEqual(sm.state, .animating(.zoomIn))
        XCTAssertEqual(effects, [.rejectBegin])
    }

    func test_begin_isRejected_fromInteractive() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: true))
        let effects = sm.handle(.begin(.zoomOut, interactive: false))
        XCTAssertEqual(sm.state, .interactive(.zoomIn))
        XCTAssertEqual(effects, [.rejectBegin])
    }

    func test_begin_isRejected_fromSettling() {
        var sm = TransitionStateMachine()
        _ = sm.handle(.begin(.zoomIn, interactive: true))
        _ = sm.handle(.release(toCompleted: true))
        let effects = sm.handle(.begin(.zoomOut, interactive: false))
        XCTAssertEqual(sm.state, .settling(.zoomIn, toCompleted: true))
        XCTAssertEqual(effects, [.rejectBegin])
    }

    // MARK: - idle no-op rule: every non-begin event from idle is a legal no-op, NOT illegal

    func test_idle_nonBeginEvents_areNoOpNotIllegal() {
        let events: [TransitionEvent] = [
            .grab,
            .update(0.5),
            .release(toCompleted: true),
            .allAnimatorsFinished,
            .forceFinish(.abandoned)
        ]
        for event in events {
            var sm = TransitionStateMachine()
            var illegalCalled = false
            let previousHandler = TransitionStateMachine.illegalTransitionHandler
            TransitionStateMachine.illegalTransitionHandler = { _ in illegalCalled = true }
            defer { TransitionStateMachine.illegalTransitionHandler = previousHandler }

            let effects = sm.handle(event)

            XCTAssertEqual(sm.state, .idle, "event \(event) should leave state idle")
            XCTAssertEqual(effects, [], "event \(event) should produce no side effects")
            XCTAssertFalse(illegalCalled, "event \(event) from idle must not be treated as illegal")
        }
    }

    // MARK: - genuine illegal transitions: combinations absent from the table AND not covered
    // by the begin-reject or idle-no-op catch-alls must call illegalTransitionHandler and
    // leave state unchanged.

    func test_illegalTransitions_callHandlerAndLeaveStateUnchanged() {
        struct Case {
            let name: String
            let setup: (inout TransitionStateMachine) -> Void
            let expectedState: TransitionState
            let illegalEvent: TransitionEvent
        }

        let cases: [Case] = [
            Case(name: "animating+update",
                 setup: { sm in _ = sm.handle(.begin(.zoomIn, interactive: false)) },
                 expectedState: .animating(.zoomIn),
                 illegalEvent: .update(0.5)),
            Case(name: "animating+release",
                 setup: { sm in _ = sm.handle(.begin(.zoomIn, interactive: false)) },
                 expectedState: .animating(.zoomIn),
                 illegalEvent: .release(toCompleted: true)),
            Case(name: "interactive+grab",
                 setup: { sm in _ = sm.handle(.begin(.zoomIn, interactive: true)) },
                 expectedState: .interactive(.zoomIn),
                 illegalEvent: .grab),
            Case(name: "interactive+allAnimatorsFinished",
                 setup: { sm in _ = sm.handle(.begin(.zoomIn, interactive: true)) },
                 expectedState: .interactive(.zoomIn),
                 illegalEvent: .allAnimatorsFinished),
            Case(name: "settling+update",
                 setup: { sm in
                     _ = sm.handle(.begin(.zoomIn, interactive: true))
                     _ = sm.handle(.release(toCompleted: true))
                 },
                 expectedState: .settling(.zoomIn, toCompleted: true),
                 illegalEvent: .update(0.5)),
            Case(name: "settling+release",
                 setup: { sm in
                     _ = sm.handle(.begin(.zoomIn, interactive: true))
                     _ = sm.handle(.release(toCompleted: true))
                 },
                 expectedState: .settling(.zoomIn, toCompleted: true),
                 illegalEvent: .release(toCompleted: false))
        ]

        for testCase in cases {
            var sm = TransitionStateMachine()
            testCase.setup(&sm)
            XCTAssertEqual(sm.state, testCase.expectedState, "setup for \(testCase.name) failed")

            var illegalCalled = false
            let previousHandler = TransitionStateMachine.illegalTransitionHandler
            TransitionStateMachine.illegalTransitionHandler = { _ in illegalCalled = true }
            defer { TransitionStateMachine.illegalTransitionHandler = previousHandler }

            let effects = sm.handle(testCase.illegalEvent)

            XCTAssertTrue(illegalCalled, "\(testCase.name) should call illegalTransitionHandler")
            XCTAssertEqual(effects, [], "\(testCase.name) should produce no side effects")
            XCTAssertEqual(sm.state, testCase.expectedState, "\(testCase.name) should leave state unchanged")
        }
    }

    // MARK: - Fuzz: seeded random event sequences must never crash and must preserve invariants.

    func test_fuzz_randomEventSequences_maintainInvariants() {
        let previousHandler = TransitionStateMachine.illegalTransitionHandler
        TransitionStateMachine.illegalTransitionHandler = { _ in /* illegal events are expected noise while fuzzing */ }
        defer { TransitionStateMachine.illegalTransitionHandler = previousHandler }

        var rng = SeededGenerator(seed: 20_260_703)

        for trial in 0..<1_000 {
            var sm = TransitionStateMachine()
            var beginCount = 0
            var cleanupCount = 0

            func step(_ event: TransitionEvent) {
                let stateBeforeWasIdle = (sm.state == .idle)
                let effects = sm.handle(event)
                if case .begin = event, stateBeforeWasIdle {
                    beginCount += 1
                }
                cleanupCount += effects.filter {
                    if case .cleanupAndComplete = $0 { return true }
                    return false
                }.count
                XCTAssertLessThanOrEqual(cleanupCount, beginCount, "trial \(trial): cleanup exceeded begins")
            }

            for _ in 0..<50 {
                step(Self.randomEvent(using: &rng))
            }

            // Drive whatever's left back to idle, ending with allAnimatorsFinished, per spec.
            switch sm.state {
            case .idle:
                break
            case .interactive:
                step(.release(toCompleted: Bool.random(using: &rng)))
                step(.allAnimatorsFinished)
            case .animating, .settling:
                step(.allAnimatorsFinished)
            }

            XCTAssertEqual(sm.state, .idle, "trial \(trial): did not return to idle after close-out")
        }
    }

    private static func randomEvent(using rng: inout SeededGenerator) -> TransitionEvent {
        let direction: Direction = Bool.random(using: &rng) ? .zoomIn : .zoomOut
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: return .begin(direction, interactive: Bool.random(using: &rng))
        case 1: return .grab
        case 2: return .update(CGFloat.random(in: 0...1, using: &rng))
        case 3: return .release(toCompleted: Bool.random(using: &rng))
        case 4: return .allAnimatorsFinished
        default:
            let reasons: [ForceReason] = [.sizeChange, .sceneBackground, .abandoned]
            return .forceFinish(reasons.randomElement(using: &rng)!)
        }
    }
}

/// Deterministic seeded PRNG (SplitMix64) so fuzz runs are reproducible across machines/CI.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
