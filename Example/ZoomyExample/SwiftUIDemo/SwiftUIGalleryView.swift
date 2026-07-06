import SwiftUI
import Zoomy

/// Grid item with a stable identity; `id` is both the `ForEach` id and the `zoomSource`/`zoomCover` key.
struct GalleryItem: Identifiable, Hashable {
    let id = UUID()
    let hue: Double
}

/// SwiftUI mirror of the UIKit grid tabs: a lazy grid whose tiles are `zoomSource`s, presenting a
/// full-screen `SwiftUIDetailView` via `zoomCover`. Reuses `DemoSettings` so the Settings tab's
/// speed/bounciness sliders drive this transition too.
struct SwiftUIGalleryView: View {

    private let items: [GalleryItem] = (0..<60).map { _ in GalleryItem(hue: .random(in: 0...1)) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    @State private var selected: GalleryItem?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Color(hue: item.hue, saturation: 0.35, brightness: 0.95)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(Text("\(index + 1)").font(.largeTitle.weight(.bold)).foregroundColor(.white.opacity(0.9)))
                        .zoomSource(id: item.id, cornerRadius: 12)
                        .onTapGesture { selected = item }
                }
            }
            .padding(8)
        }
        .navigationTitle("SwiftUI")
        .zoomCover(item: $selected, configuration: DemoSettings.shared.makeConfiguration()) { item in
            SwiftUIDetailView(item: item) { selected = nil }
        }
    }
}
