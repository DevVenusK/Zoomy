import UIKit
import os.log

/// Process-wide registry mapping a `zoomSource(id:)` id to the live marker `UIView` planted in the
/// SwiftUI hierarchy. `zoomCover`'s `sourceViewProvider` looks the view up by id at animation time.
/// Views are held weakly, so a marker that scrolls out of a lazy container (its representable is
/// dismantled) or is otherwise torn down auto-evicts and the provider cleanly returns `nil` — the
/// engine then falls back to a cross-dissolve. Internal; not consumer API.
@MainActor
final class ZoomSourceRegistry {

    static let shared = ZoomSourceRegistry()

    private final class WeakBox {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var storage: [AnyHashable: WeakBox] = [:]

    /// Registers `view` for `id` (last-writer-wins). A live collision — a *different*, still-alive
    /// view already registered for `id` — is a caller bug (ids must be unique/stable); logged in DEBUG.
    func register(_ view: UIView, for id: AnyHashable) {
        #if DEBUG
        if let existing = storage[id]?.view, existing !== view {
            os_log(
                "Two live zoomSource views share id %{public}@ — ids must be unique",
                log: .zoomy,
                type: .error,
                String(describing: id)
            )
        }
        #endif
        storage[id] = WeakBox(view)
    }

    /// Removes only the entries pointing at `view` (and prunes any dead ones). Identity-guarded so a
    /// stale marker being dismantled after a newer marker claimed the same id can't evict the newer.
    func deregister(_ view: UIView) {
        storage = storage.filter { $0.value.view !== view && $0.value.view != nil }
    }

    /// The live view for `id`, pruning the entry if its weak ref has died.
    func view(for id: AnyHashable) -> UIView? {
        guard let box = storage[id] else { return nil }
        guard let view = box.view else {
            storage[id] = nil
            return nil
        }
        return view
    }
}
