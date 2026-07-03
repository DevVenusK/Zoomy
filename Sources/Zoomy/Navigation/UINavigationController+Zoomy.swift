import UIKit

private let zoomNavigationDelegateKey = AssociatedObjects.Key()

extension UINavigationController {
    /// Installs a ``ZoomNavigationDelegate`` that adds Zoomy's push/pop zoom while forwarding every
    /// other navigation-delegate message to whatever delegate was already set.
    ///
    /// Idempotent: if the current `delegate` is already a `ZoomNavigationDelegate`, that instance is
    /// returned unchanged. Otherwise the current delegate becomes the new proxy's
    /// ``ZoomNavigationDelegate/downstream``. The proxy is retained via an associated object because
    /// `UINavigationController.delegate` is `weak`.
    ///
    /// - Returns: the installed (or already-installed) proxy, so the caller can hold it or observe
    ///   `ZoomTransition`s through it.
    @discardableResult
    public func enableZoomTransitions() -> ZoomNavigationDelegate {
        if let existing = delegate as? ZoomNavigationDelegate {
            return existing
        }

        let proxy = ZoomNavigationDelegate(forwardingTo: delegate)
        proxy.navigationController = self
        // Retain the proxy first — `delegate` is weak, so this associated object is the only owner.
        AssociatedObjects.set(self, zoomNavigationDelegateKey, proxy)
        delegate = proxy
        return proxy
    }
}
