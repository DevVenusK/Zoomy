import UIKit

/// Observes `UIScene.didEnterBackgroundNotification` and invokes `onBackground` **only** when the
/// notification comes from the scene the observed transition lives in (`docs/TECH_SPEC.md` §7.10).
///
/// The app-scope `UIApplication.didEnterBackgroundNotification` does *not* fire per-scene on an iPad
/// with multiple windows, so a per-scene filter is required: we register for the scene-scoped
/// notification and compare its object against the container's window scene by identity. The scene is
/// held as `AnyObject` (compared with `===`) rather than a typed `UIWindowScene` so the filtering can
/// be exercised from a unit test with a plain object stand-in (a real `UIWindowScene` can't be built
/// in a test). No swizzling, no KVO.
@MainActor
final class SceneBackgroundObserver {

    /// The scene whose backgrounding we react to. `weak`/`AnyObject` — UIKit owns the scene; a `nil`
    /// scene (container not yet in a window at install time) simply never matches.
    private weak var targetScene: AnyObject?
    private let onBackground: () -> Void

    init(scene: AnyObject?, onBackground: @escaping () -> Void) {
        self.targetScene = scene
        self.onBackground = onBackground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidEnterBackground(_:)),
            name: UIScene.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func sceneDidEnterBackground(_ note: Notification) {
        guard let targetScene, (note.object as AnyObject?) === targetScene else { return }
        // Retain self across the callback: `onBackground` runs the transition's forceFinish, whose
        // cleanup can drop the last strong reference to us (we're owned by the driver). Deallocating
        // mid-selector would be a use-after-free.
        withExtendedLifetime(self) {
            onBackground()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
