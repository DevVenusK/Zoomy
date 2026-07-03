import UIKit

/// The morphing "window" a zoom transition flies the live destination view inside — a plain
/// clipping container whose frame lerps between the source rect and the destination's final
/// frame while the live view (hosted in `contentContainer`) counter-scales inside it.
///
/// See `docs/TECH_SPEC.md` §5.5 / §6.1 (container stack).
final class PortalView: UIView {

    /// Hosts the live destination (or, during dismissal, departing) view. Tracks the portal's
    /// bounds via autoresizing so it participates in the same inherited frame animation as the
    /// portal itself.
    let contentContainer = UIView()

    /// The source snapshot ("placard") cross-faded over the live view near the source end of
    /// the flight. Setting replaces any previous placard and keeps it topmost; it stretches
    /// with the portal via autoresizing.
    var placardView: UIView? {
        didSet {
            guard placardView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let placardView {
                placardView.frame = bounds
                placardView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(placardView) // topmost — above contentContainer
            }
        }
    }

    /// Forwards to `layer.cornerRadius`, clamped to `min(bounds.width, bounds.height) / 2` at
    /// set time so the radius never exceeds what the current (model-layer) rect can render.
    /// The clamp reads the *model* bounds — when set inside an animation block whose geometry
    /// animator has already stamped the final frame, it clamps against the final rect, which is
    /// exactly the end value the corner morph should animate to (see `TransitionDriver`'s
    /// animator start order).
    var portalCornerRadius: CGFloat {
        get { layer.cornerRadius }
        set { layer.cornerRadius = max(0, min(newValue, min(bounds.width, bounds.height) / 2)) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
