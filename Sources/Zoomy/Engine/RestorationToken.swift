import UIKit

/// Records "undo" closures for transient mutations a transition makes to the outside world
/// (hiding the source view, disabling scroll, pinning safe-area insets, ...), then unwinds them
/// in reverse order exactly once. Every helper here is only ever asked to restore a stored
/// *original* value it captured itself — see `docs/TECH_SPEC.md` §5.4.
///
/// `deinit` is a backstop for a token that was allocated but never explicitly `restore()`d
/// (an abandoned/torn-down transition context) — it must not leave the app in a mutated state.
///
/// Concurrency note: this type is `@MainActor` because every mutation it undoes is a UIKit
/// call. `deinit`, however, is *not* actor-isolated in this Swift version (a plain
/// `@MainActor` class's deinit always runs nonisolated — see SE-0327/discussion around
/// "isolated deinit", not yet available here) — calling the `@MainActor`-isolated `restore()`
/// method from `deinit` would be a compile error ("call to main actor-isolated instance method
/// in a synchronous nonisolated context"). Instead `deinit` inlines the same logic: it only
/// touches `self`'s own stored properties (always permitted from a type's own deinit,
/// regardless of actor isolation) and invokes the recorded closures directly — their static
/// type is the plain, non-isolated `() -> Void`, so calling them carries no actor requirement
/// at the type level. This relies on the library's own contract that these tokens are only ever
/// created/dropped from the main thread, matching every other UIKit-touching type here.
@MainActor
final class RestorationToken {
    private var restorations: [() -> Void] = []
    private var didRestore = false

    /// Registers an undo step. Callers must capture any view/controller `weak` — a token can
    /// outlive the thing it's restoring (e.g. the transition is abandoned mid-flight).
    func record(_ restore: @escaping () -> Void) {
        restorations.append(restore)
    }

    /// Idempotent: only the first call actually runs anything. Runs in reverse recording order
    /// so later mutations (which may depend on earlier ones still being in their "installed"
    /// state) get undone first.
    func restore() {
        guard !didRestore else { return }
        didRestore = true
        let pending = restorations
        restorations.removeAll()
        for undo in pending.reversed() {
            undo()
        }
    }

    deinit {
        guard !didRestore else { return }
        didRestore = true
        for undo in restorations.reversed() {
            undo()
        }
    }
}

// MARK: - Convenience recorders

extension RestorationToken {
    func recordHide(of view: UIView) {
        let original = view.isHidden
        record { [weak view] in view?.isHidden = original }
    }

    func recordAlpha(of view: UIView) {
        let original = view.alpha
        record { [weak view] in view?.alpha = original }
    }

    func recordScrollLock(of scrollView: UIScrollView) {
        let original = scrollView.isScrollEnabled
        record { [weak scrollView] in scrollView?.isScrollEnabled = original }
    }

    func recordAdditionalSafeAreaInsets(of viewController: UIViewController) {
        let original = viewController.additionalSafeAreaInsets
        record { [weak viewController] in viewController?.additionalSafeAreaInsets = original }
    }

    func recordTransform(of view: UIView) {
        let original = view.transform
        record { [weak view] in view?.transform = original }
    }
}
