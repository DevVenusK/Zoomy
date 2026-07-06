import SwiftUI

/// Full-bleed detail shown by the SwiftUI demo's `zoomCover`. Uses an OPAQUE background — a
/// transparent hosted view would let the portal reveal the presenter behind the destination.
struct SwiftUIDetailView: View {

    let item: GalleryItem
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hue: item.hue, saturation: 0.5, brightness: 0.9)
                .ignoresSafeArea()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
        }
    }
}
