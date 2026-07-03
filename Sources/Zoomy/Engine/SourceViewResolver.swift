import UIKit

/// The source view Zoomy will morph the portal out of/into, plus everything geometry needs,
/// already expressed in `containerView`'s coordinate space.
struct ResolvedSource {
    let view: UIView
    /// Presentation-layer rect when the view is mid-animation, otherwise its model-layer frame.
    let rectInContainer: CGRect
    /// `rectInContainer` intersected with every clipping ancestor's bounds.
    let visibleRectInContainer: CGRect
    /// Presentation-layer corner radius when available, otherwise the model-layer value.
    let cornerRadius: CGFloat
    /// A `snapshotView(afterScreenUpdates: false)` of the source, or `nil` if UIKit couldn't
    /// produce one — the caller must tolerate a missing placard (see `docs/TECH_SPEC.md` §5.5).
    let placard: UIView?
}

/// Why `SourceViewResolver.resolve` couldn't produce a `ResolvedSource`. Every case maps to one
/// rung of the validation ladder in `resolve`'s doc comment.
///
/// Conforms to `Error` solely because `Swift.Result`'s `Failure` generic parameter requires it —
/// nothing here is ever `throw`n.
enum ResolutionFailure: Equatable, Error {
    case providerNil
    case detached
    case insideZoomedHierarchy
    case hiddenAncestor
    case insufficientVisibility(ratio: CGFloat)
    case offContainer
}

/// Validates and geometrically resolves whatever view `ZoomTransition.SourceViewProvider`
/// hands back, so a bad answer (detached view, hidden ancestor, mostly-scrolled-out cell, ...)
/// degrades to `.fellBack(.sourceUnresolved)` instead of animating garbage.
@MainActor
enum SourceViewResolver {
    /// Below this visible-area fraction, the source is considered too obscured to anchor a
    /// zoom to (see `docs/TECH_SPEC.md` §5.3/§7.5).
    static let visibilityThreshold: CGFloat = 0.35

    /// Validation ladder, in this exact order:
    /// 1. `provider(context)` returns `nil` → `.providerNil`.
    /// 2. The returned view has no `window` → `.detached`.
    /// 3. The view is inside `zoomedView`'s own hierarchy (a provider bug — the destination
    ///    can't be its own source) → asserts + `.insideZoomedHierarchy`.
    /// 4. Walking ancestors from the view itself up through its window, any `isHidden` or
    ///    `alpha < 0.01` → `.hiddenAncestor`.
    /// 5. The rect is taken from the presentation layer if one is mid-animation, else the model
    ///    frame, then converted into `containerView`'s space.
    /// 6. Every clipping ancestor's bounds (converted into container space) are intersected
    ///    into a visible rect; if the visible/full area ratio is below `visibilityThreshold` →
    ///    `.insufficientVisibility(ratio:)` (or `.offContainer` if the full rect has zero area).
    /// 7. If the rect doesn't intersect the container bounds (outset by 8pt) → `.offContainer`.
    /// 8. Success: a best-effort snapshot placard (nil allowed) and corner radius are attached.
    static func resolve(
        provider: ZoomTransition.SourceViewProvider,
        context: ZoomTransition.Context,
        zoomedView: UIView,
        containerView: UIView
    ) -> Result<ResolvedSource, ResolutionFailure> {
        // 1. Provider.
        guard let view = provider(context) else {
            return .failure(.providerNil)
        }

        // 2. Detached.
        guard view.window != nil else {
            return .failure(.detached)
        }

        // 3. Provider returned a view inside the destination's own hierarchy — a contract
        //    violation (see `ZoomTransition.SourceViewProvider`'s doc comment).
        if view.isDescendant(of: zoomedView) {
            ZoomyAssert.fail(
                "sourceViewProvider returned a view inside the zoomed destination's own hierarchy"
            )
            return .failure(.insideZoomedHierarchy)
        }

        // 4. Hidden ancestor walk (self included, up through the window).
        var hiddenWalk: UIView? = view
        while let current = hiddenWalk {
            if current.isHidden || current.alpha < 0.01 {
                return .failure(.hiddenAncestor)
            }
            hiddenWalk = current.superview
        }

        // 5. Rect, presentation-layer first.
        let rectInOwnSpace: CGRect
        if let animationKeys = view.layer.animationKeys(), !animationKeys.isEmpty {
            rectInOwnSpace = view.layer.presentation()!.frame
        } else {
            rectInOwnSpace = view.frame
        }
        let rectInContainer: CGRect
        if let superview = view.superview {
            rectInContainer = superview.convert(rectInOwnSpace, to: containerView)
        } else {
            rectInContainer = view.convert(view.bounds, to: containerView)
        }

        // 6. Visible rect: intersect every clipping ancestor's bounds (converted into container
        //    space), starting from the view's superview (a view's own `clipsToBounds` affects
        //    its *subviews*, not how much of itself its own superview shows).
        var visibleRectInContainer = rectInContainer
        var clipWalk: UIView? = view.superview
        while let current = clipWalk {
            if current.clipsToBounds || current.layer.masksToBounds {
                let clipRectInContainer = current.convert(current.bounds, to: containerView)
                visibleRectInContainer = visibleRectInContainer.intersection(clipRectInContainer)
            }
            clipWalk = current.superview
        }

        let fullArea = rectInContainer.width * rectInContainer.height
        guard fullArea != 0 else {
            return .failure(.offContainer)
        }
        let visibleArea = visibleRectInContainer.isNull
            ? 0
            : visibleRectInContainer.width * visibleRectInContainer.height
        let visibilityRatio = visibleArea / fullArea
        guard visibilityRatio >= visibilityThreshold else {
            return .failure(.insufficientVisibility(ratio: visibilityRatio))
        }

        // 7. Container intersection, with an 8pt margin.
        let expandedContainerBounds = containerView.bounds.insetBy(dx: -8, dy: -8)
        guard rectInContainer.intersects(expandedContainerBounds) else {
            return .failure(.offContainer)
        }

        // 8. Success.
        let placard = view.snapshotView(afterScreenUpdates: false)
        let cornerRadius = view.layer.presentation()?.cornerRadius ?? view.layer.cornerRadius

        return .success(ResolvedSource(
            view: view,
            rectInContainer: rectInContainer,
            visibleRectInContainer: visibleRectInContainer,
            cornerRadius: cornerRadius,
            placard: placard
        ))
    }
}
