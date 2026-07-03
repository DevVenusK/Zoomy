import UIKit

private let zoomTransitionKey = AssociatedObjects.Key()
private let zoomTransitionSnapshotKey = AssociatedObjects.Key()

/// The view controller's modal presentation wiring exactly as it was before Zoomy installed
/// itself, so a later `zoomTransition = nil` can put it back untouched — including whatever
/// non-default style the app had already set (e.g. `.overFullScreen`), never a hardcoded
/// constant.
///
/// `transitioningDelegate` is captured `weak` to mirror `UIViewController.transitioningDelegate`
/// itself, which is `weak` — snapshotting it `strong` would extend that delegate's lifetime
/// beyond what the app itself guarantees.
private struct ModalPresentationSnapshot {
    let style: UIModalPresentationStyle
    weak var transitioningDelegate: UIViewControllerTransitioningDelegate?
}

extension UIViewController {
    /// The `ZoomTransition` driving this view controller's push/present appearance, if any.
    ///
    /// Setter semantics, in order:
    /// 1. Asserts (does not crash) if this VC has already been presented — reassigning after
    ///    `present` is a programmer error, since UIKit already read `transitioningDelegate`.
    /// 2. Rejects (with an assert, no-op) attaching a `ZoomTransition` instance that's already
    ///    attached to a *different* view controller — one instance per view controller.
    /// 3. On first install, snapshots the current `(modalPresentationStyle,
    ///    transitioningDelegate)` so it can be restored later. A snapshot already present from
    ///    an earlier install is left alone. When replacing a previously-installed *different*
    ///    transition instance, the old instance's `attachedViewController` back-reference is
    ///    released first so it can be legitimately attached elsewhere later.
    /// 4. Installs `.custom` / `newValue.modalAdapter` and records `self` as the transition's
    ///    `attachedViewController`.
    /// 5. Retains the transition via an associated object — `transitioningDelegate` is `weak`,
    ///    so this is the only thing keeping it alive.
    /// 6. Assigning `nil` restores the snapshotted style/delegate *only if* the current
    ///    `transitioningDelegate` is still our own adapter (an app that installed its own
    ///    delegate afterward is left alone), then clears the associated storage and the old
    ///    transition's `attachedViewController`.
    public var zoomTransition: ZoomTransition? {
        get {
            AssociatedObjects.get(self, zoomTransitionKey)
        }
        set {
            ZoomyAssert.precondition(
                presentingViewController == nil,
                "Assigning zoomTransition after this view controller has been presented is not allowed"
            )

            guard let newValue else {
                detachZoomTransition()
                return
            }

            if let attached = newValue.attachedViewController, attached !== self {
                ZoomyAssert.fail(
                    "A ZoomTransition instance may only be attached to one view controller at a time — create a new instance"
                )
                return
            }

            // Replacing one transition with a different instance (without going through nil)
            // must release the old instance's back-reference — otherwise it would stay
            // "attached" to this VC forever and be falsely rejected by the double-attachment
            // guard above when later attached to another VC. The snapshot is deliberately kept:
            // it records the app's own pre-Zoomy style/delegate, and installing the new value
            // overwrites the live style/delegate below anyway.
            if let previous: ZoomTransition = AssociatedObjects.get(self, zoomTransitionKey),
               previous !== newValue {
                previous.attachedViewController = nil
            }

            let existingSnapshot: ModalPresentationSnapshot? =
                AssociatedObjects.get(self, zoomTransitionSnapshotKey)
            if existingSnapshot == nil {
                let snapshot = ModalPresentationSnapshot(
                    style: modalPresentationStyle,
                    transitioningDelegate: transitioningDelegate
                )
                AssociatedObjects.set(self, zoomTransitionSnapshotKey, snapshot)
            }

            modalPresentationStyle = .custom
            transitioningDelegate = newValue.modalAdapter
            newValue.attachedViewController = self

            AssociatedObjects.set(self, zoomTransitionKey, newValue)
        }
    }

    private func detachZoomTransition() {
        if let existing: ZoomTransition = AssociatedObjects.get(self, zoomTransitionKey) {
            if transitioningDelegate === existing.modalAdapter {
                let snapshot: ModalPresentationSnapshot? =
                    AssociatedObjects.get(self, zoomTransitionSnapshotKey)
                if let snapshot {
                    modalPresentationStyle = snapshot.style
                    transitioningDelegate = snapshot.transitioningDelegate
                }
            }
            existing.attachedViewController = nil
        }
        AssociatedObjects.remove(self, zoomTransitionKey)
        AssociatedObjects.remove(self, zoomTransitionSnapshotKey)
    }
}
