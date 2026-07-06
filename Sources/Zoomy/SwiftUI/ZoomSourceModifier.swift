#if canImport(SwiftUI)
import SwiftUI
import UIKit

/// Transparent, non-interactive marker planted behind a `zoomSource` view. Zoomy's
/// `SourceViewResolver` resolves the on-screen source rect and corner radius from this real
/// `UIView`; its (blank) snapshot placard is an explicitly-tolerated case.
final class ZoomSourceMarkerView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Backs `View.zoomSource(id:cornerRadius:)`. Planted as a `.background`, it matches the source
/// view's frame without affecting layout, and register/deregisters itself across its lifetime.
struct ZoomSourceMarker: UIViewRepresentable {

    let id: AnyHashable
    let cornerRadius: CGFloat

    func makeUIView(context: Context) -> ZoomSourceMarkerView {
        let view = ZoomSourceMarkerView()
        view.layer.cornerRadius = cornerRadius
        ZoomSourceRegistry.shared.register(view, for: id)
        return view
    }

    func updateUIView(_ view: ZoomSourceMarkerView, context: Context) {
        view.layer.cornerRadius = cornerRadius
        // Only touch the registry when the mapping actually needs to change: on the common
        // re-render (same id, same view) this is a no-op, avoiding an O(n) dictionary sweep per
        // tile. When the id bound to this reused view changed across a SwiftUI diff, clear any
        // prior mapping for this exact view, then re-register under the current id.
        guard ZoomSourceRegistry.shared.view(for: id) !== view else { return }
        ZoomSourceRegistry.shared.deregister(view)
        ZoomSourceRegistry.shared.register(view, for: id)
    }

    static func dismantleUIView(_ view: ZoomSourceMarkerView, coordinator: ()) {
        ZoomSourceRegistry.shared.deregister(view)
    }
}

public extension View {

    /// Marks this view as the zoom source registered under `id`. Plants a transparent marker view
    /// (as a `.background`, so no layout impact) that Zoomy resolves the source rect from. `id` must
    /// equal the `Identifiable` id of the item presented via `zoomCover(item:)`; `cornerRadius` is
    /// applied to the marker so `Configuration.cornerMorph == .automatic` reads it.
    func zoomSource<ID: Hashable>(id: ID, cornerRadius: CGFloat = 0) -> some View {
        background(ZoomSourceMarker(id: AnyHashable(id), cornerRadius: cornerRadius))
    }
}
#endif
