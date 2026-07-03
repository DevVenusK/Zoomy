import UIKit

/// Observes a `ZoomTransition`'s lifecycle. `willBegin` fires immediately before source
/// resolution — the last chance for the app to restore state (e.g.
/// `scrollToItem(animated: false)` + `layoutIfNeeded()`) so the provider sees the right layout.
/// `didEnd` fires exactly once, right after cleanup completes.
@MainActor
public protocol ZoomTransitionDelegate: AnyObject {
    func zoomTransition(_ transition: ZoomTransition, willBegin context: ZoomTransition.Context)
    func zoomTransition(_ transition: ZoomTransition, didEnd context: ZoomTransition.Context,
                        result: ZoomTransition.Result)
}

public extension ZoomTransitionDelegate {
    func zoomTransition(_: ZoomTransition, willBegin _: ZoomTransition.Context) {}
    func zoomTransition(_: ZoomTransition, didEnd _: ZoomTransition.Context,
                        result _: ZoomTransition.Result) {}
}
