import UIKit

/// Estimates the corner radius a zoomed destination should morph *to* when
/// `Configuration.CornerMorph.automatic` is in effect and no explicit radius was given.
///
/// Device corner radii aren't published by a public API, so this deliberately does not try to
/// look one up per-model (no private `UIScreen` key-value lookups, no hardware model table).
/// Instead it uses a single conservative estimate for the one case that matters — the
/// destination visually fills the device screen, edge-to-edge — and 0 everywhere else (split
/// view, a sheet, an inset container, ...). Consumers who need a different value can override
/// via `Configuration.CornerMorph.fixed`.
@MainActor
enum ContainerCornerRadius {
    static let fullScreenEstimate: CGFloat = 39

    /// `containerView.bounds == window.bounds ∧ window.frame == window.screen.bounds` →
    /// `fullScreenEstimate`; otherwise 0. Never reads `UIScreen.main` — only ever
    /// `window.screen`, so this respects whichever screen the window actually lives on.
    static func automaticFinalRadius(for containerView: UIView) -> CGFloat {
        guard let window = containerView.window else { return 0 }
        guard containerView.bounds == window.bounds else { return 0 }
        guard window.frame == window.screen.bounds else { return 0 }
        return fullScreenEstimate
    }
}
