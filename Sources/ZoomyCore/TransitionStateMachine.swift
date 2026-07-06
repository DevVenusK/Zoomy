import CoreGraphics

public enum Direction: Equatable {
    case zoomIn
    case zoomOut
}

public enum TransitionState: Equatable {
    case idle
    case animating(Direction)
    case interactive(Direction)
    case settling(Direction, toCompleted: Bool)
}

public enum ForceReason: Equatable {
    case sizeChange
    case sceneBackground
    case abandoned
}

public enum TransitionEvent: Equatable {
    case begin(Direction, interactive: Bool)
    case grab
    case update(CGFloat)          // radial progress 0...1
    case release(toCompleted: Bool)
    case allAnimatorsFinished
    case forceFinish(ForceReason)
}

public enum SideEffect: Equatable {
    case startAnimators
    case startPausedForGesture
    case freezeGeometryAndPauseTransition
    case applyFollow(CGFloat)
    case settle(toCompleted: Bool)
    case fastForwardAll(toCompleted: Bool)
    case cleanupAndComplete(completed: Bool)
    case rejectBegin
}

/// Pure transition state machine — no UIKit dependency. Drives which side effects the
/// (UIKit-aware) engine layer must perform in response to lifecycle/gesture events.
public struct TransitionStateMachine {
    public private(set) var state: TransitionState = .idle

    /// Radial progress from the most recent `update(_:)` while `.interactive`. Used to decide
    /// completion direction when a `forceFinish` arrives mid-gesture. Resets to 0 on return to idle.
    public private(set) var lastProgress: CGFloat = 0

    /// DEBUG에서 불법 전이 시 호출. 기본값은 debug assertionFailure, 테스트에서 교체 가능.
    public static var illegalTransitionHandler: (String) -> Void = { message in
        assertionFailure(message)
    }

    public init() {}

    @discardableResult
    public mutating func handle(_ event: TransitionEvent) -> [SideEffect] {
        switch (state, event) {
        case (.idle, .begin(let direction, false)):
            state = .animating(direction)
            return [.startAnimators]

        case (.idle, .begin(let direction, true)):
            state = .interactive(direction)
            return [.startPausedForGesture]

        case (.animating(let direction), .grab):
            state = .interactive(direction)
            return [.freezeGeometryAndPauseTransition]

        case (.animating, .allAnimatorsFinished):
            state = .idle
            lastProgress = 0
            return [.cleanupAndComplete(completed: true)]

        case (.interactive(let direction), .update(let progress)):
            lastProgress = progress
            state = .interactive(direction)
            return [.applyFollow(progress)]

        case (.interactive(let direction), .release(let toCompleted)):
            state = .settling(direction, toCompleted: toCompleted)
            return [.settle(toCompleted: toCompleted)]

        case (.settling(let direction, _), .grab):
            state = .interactive(direction)
            return [.freezeGeometryAndPauseTransition]

        case (.settling(_, let toCompleted), .allAnimatorsFinished):
            state = .idle
            lastProgress = 0
            return [.cleanupAndComplete(completed: toCompleted)]

        case (.animating, .forceFinish):
            state = .idle
            lastProgress = 0
            return [.fastForwardAll(toCompleted: true), .cleanupAndComplete(completed: true)]

        case (.interactive, .forceFinish):
            let completed = lastProgress > 0.5
            state = .idle
            lastProgress = 0
            return [.fastForwardAll(toCompleted: completed), .cleanupAndComplete(completed: completed)]

        case (.settling(_, let toCompleted), .forceFinish):
            state = .idle
            lastProgress = 0
            return [.fastForwardAll(toCompleted: toCompleted), .cleanupAndComplete(completed: toCompleted)]

        case (.animating, .begin), (.interactive, .begin), (.settling, .begin):
            return [.rejectBegin]

        case (.idle, _):
            // Delayed/late-arriving events while idle are legal no-ops, not illegal transitions.
            return []

        default:
            Self.illegalTransitionHandler("Illegal transition: \(event) in state \(state)")
            return []
        }
    }
}
