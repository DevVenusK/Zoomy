/// Which SwiftUI zoom-cover presentation state we are in. The `AnyHashable` payload is the id of
/// the item being presented (`Item.id` from `View.zoomCover(item:)`).
public enum ZoomCoverPhase: Equatable {
    case idle
    case presenting(AnyHashable)
    case presented(AnyHashable)
    case dismissing
}

/// The single side effect the SwiftUI coordinator must perform for a given (desired, phase) pair.
public enum ZoomCoverAction: Equatable {
    case present(AnyHashable)
    case dismiss
    case none
}

/// Pure decision core for `View.zoomCover(item:)` — no SwiftUI/UIKit dependency, mirroring
/// `TransitionStateMachine`. `next` maps the desired binding value (`item?.id`) and the current
/// `phase` to exactly one action; `presenting`/`dismissing` are in-flight, so every change during
/// them is deferred (`.none`) and re-evaluated when the coordinator advances the phase on
/// completion. This is what keeps SwiftUI's re-entrant update path, rapid re-taps, and the
/// delegate-driven binding write from looping.
public enum ZoomCoverReducer {

    public static func next(desired: AnyHashable?, phase: ZoomCoverPhase) -> ZoomCoverAction {
        switch (desired, phase) {
        case (.some(let id), .idle):
            return .present(id)
        case (.none, .presented):
            return .dismiss
        case (.some(let id), .presented(let current)):
            return id == current ? .none : .dismiss
        case (_, .presenting), (_, .dismissing):
            return .none
        case (.none, .idle):
            return .none
        }
    }

    /// The phase after a present/dismiss animation completes, before the next `next` runs.
    public static func advanced(_ phase: ZoomCoverPhase) -> ZoomCoverPhase {
        switch phase {
        case .presenting(let id): return .presented(id)
        case .dismissing:         return .idle
        case .idle, .presented:   return phase
        }
    }

    /// Whether an engine-reported `didEnd` should sync the binding back to `nil` — i.e. a completed
    /// dismiss we did not initiate (interactive pan / VoiceOver escape / force-finish). A programmatic
    /// dismiss is in `.dismissing`, so `isPresentedPhase` is `false` and its completion handler owns
    /// the sync instead; a cancelled drag reports `isCompleted == false`.
    public static func shouldSyncOnDidEnd(isDismiss: Bool, isCompleted: Bool, isPresentedPhase: Bool) -> Bool {
        isDismiss && isCompleted && isPresentedPhase
    }
}
