import UIKit
import os.log

/// Drives a "zoom" transition (a la iOS's home-screen app-open animation) between a source view
/// somewhere on screen and a destination view controller being pushed/presented, generalized to
/// UIKit's push/pop and present/dismiss. Attach one instance per destination view controller via
/// `UIViewController.zoomTransition`.
@MainActor
public final class ZoomTransition: NSObject {

    /// Called on the main thread at the start of every animation phase (present, the start of a
    /// dismiss, and again at settle). Contract: must be pure — no layout mutation, no
    /// navigation calls — and the returned view must belong to the *non-transitioning* side's
    /// hierarchy (never a subview of the destination itself). Returning `nil` falls back to
    /// `configuration.fallback`.
    public typealias SourceViewProvider = (Context) -> UIView?

    /// Immutable for the lifetime of this transition.
    public let configuration: Configuration
    public weak var delegate: ZoomTransitionDelegate?

    /// The interactive dismiss/pop pan recognizer, once it has been installed on the destination
    /// view (M6). `nil` until the destination finishes appearing and the driver installs it, or
    /// when `configuration.interactiveDismissal == .disabled`.
    public var dismissalPanGesture: UIPanGestureRecognizer? {
        guard configuration.interactiveDismissal == .pan,
              let gesture = interactionDriver?.panGesture,
              gesture.view != nil else { return nil }
        return gesture
    }

    let sourceViewProvider: SourceViewProvider
    /// The accessibility flags the vend-time gating (§9) reads. Defaults to the live `UIAccessibility`
    /// state; swapped for a stub in tests (those flags can't be toggled from a unit test). Internal
    /// seam only — never public.
    var accessibilityEnvironment: any AccessibilityEnvironment = SystemAccessibilityEnvironment()
    weak var attachedViewController: UIViewController?
    /// Recorded when this transition's destination is pushed, so a subsequent pop can tell
    /// whether it's returning to the view controller it was pushed *from* (M4).
    weak var pushPredecessor: UIViewController?
    var stateMachine = TransitionStateMachine()
    lazy var modalAdapter = ModalTransitioningAdapter(transition: self)

    /// Non-nil only while a transition is in flight — holds the animators, animation context,
    /// and `UIViewControllerContextTransitioning` for the current run (see `ActiveTransition`).
    /// Dropped to `nil` by the driver's single-exit cleanup.
    var activeTransition: ActiveTransition?
    /// The driver running `activeTransition`, retained here for the transition's duration so it
    /// outlives UIKit's own hold; released alongside `activeTransition` at cleanup.
    var currentDriver: TransitionDriver?

    /// The interactive dismiss/pop driver (M6), lazily created the first time the destination is
    /// eligible for an interactive dismissal. Retained for the transition's whole lifetime (not
    /// dropped at cleanup) so a cancelled drag can be re-grabbed and the installed pan recognizer's
    /// weak target stays alive; deallocates with the transition (i.e. with its view controller).
    var interactionDriver: ZoomInteractionDriver?

    /// Returns the (lazily created) interactive driver for `operation`, memoised across dismissals.
    /// A transition instance drives exactly one destination, so its interactive operation
    /// (`.dismiss` for modal, `.pop` for navigation) is fixed on first use.
    func makeInteractionDriver(operation: Operation) -> ZoomInteractionDriver {
        if let existing = interactionDriver { return existing }
        let driver = ZoomInteractionDriver(transition: self, phase: .disappearing, operation: operation)
        interactionDriver = driver
        return driver
    }

    public init(configuration: Configuration = .default, sourceViewProvider: @escaping SourceViewProvider) {
        self.configuration = configuration
        self.sourceViewProvider = sourceViewProvider
        super.init()
    }

    func reportWillBegin(_ context: Context) {
        delegate?.zoomTransition(self, willBegin: context)
    }

    func reportDidEnd(_ context: Context, result: Result) {
        delegate?.zoomTransition(self, didEnd: context, result: result)
        #if DEBUG
        if let reason = result.fallbackReason {
            os_log(
                "ZoomTransition fell back to the system default (reason: %{public}@)",
                log: .zoomy,
                type: .debug,
                String(describing: reason)
            )
        }
        #endif
    }
}

extension ZoomTransition {
    public enum Phase: Sendable { case appearing, disappearing }
    public enum Operation: Sendable { case push, pop, present, dismiss }

    /// Snapshot of "what's happening" handed to `SourceViewProvider` and the delegate at the
    /// start of every animation phase.
    public struct Context {
        public weak var zoomedViewController: UIViewController?
        public weak var sourceViewController: UIViewController?
        public let phase: Phase
        public let operation: Operation
        public let isInteractive: Bool
    }

    /// Delivered to `didEnd` exactly once per transition.
    public struct Result: Equatable, Sendable {
        /// `false` means the transition was cancelled (dismiss aborted, drag released short).
        public let isCompleted: Bool
        public let wasInteractive: Bool
        /// Non-nil if a zoom couldn't run and `configuration.fallback` took over instead.
        public let fallbackReason: FallbackReason?
    }

    public enum FallbackReason: Equatable, Sendable {
        /// The provider returned `nil`, or the returned view failed the resolution ladder.
        case sourceUnresolved
        /// A `zoomTransition` is attached but the delegate chain never reached it (diagnostic).
        case notWired
        /// `begin` arrived while the state machine wasn't `.idle`.
        case reentrant
        /// Reduce Motion / VoiceOver short-circuited to a non-zoom animation.
        case reduceMotion
        /// The requested navigation operation isn't one Zoomy handles (multi-pop, etc).
        case unsupportedOperation
    }

    public struct Configuration {
        public static let `default` = Configuration()

        public var spring: Spring = .init(response: 0.44, dampingRatio: 0.85)
        /// `nil` means no dimming view at all.
        public var dimmingColor: UIColor? = UIColor.black.withAlphaComponent(0.3)
        public var cornerMorph: CornerMorph = .automatic
        public var interactiveDismissal: InteractiveDismissal = .pan
        public var fallback: Fallback = .crossDissolve
        public var respectsReduceMotion: Bool = true
        public var resignsFirstResponders: Bool = true

        public init() {}

        public enum CornerMorph: Equatable {
            /// Source's `layer.cornerRadius` → the container's contextual radius (see
            /// `ContainerCornerRadius`).
            case automatic
            case fixed(from: CGFloat, to: CGFloat)
            case none
        }

        public enum InteractiveDismissal: Equatable { case pan, disabled }
        public enum Fallback: Equatable { case crossDissolve, systemDefault }
    }

    public struct Spring: Hashable, Sendable {
        /// Approximates perceived duration.
        public var response: TimeInterval
        public var dampingRatio: CGFloat

        public init(response: TimeInterval, dampingRatio: CGFloat) {
            self.response = response
            self.dampingRatio = dampingRatio
        }
    }
}

extension OSLog {
    static let zoomy = OSLog(subsystem: "com.zoomy.Zoomy", category: "transition")
}
