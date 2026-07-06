import XCTest
import UIKit
@testable import Zoomy

@MainActor
final class ZoomSourceMarkerViewTests: XCTestCase {

    func test_markerView_isTransparentAndNonInteractive() {
        let view = ZoomSourceMarkerView()
        XCTAssertFalse(view.isUserInteractionEnabled, "marker must never intercept touches")
        XCTAssertEqual(view.backgroundColor, .clear, "marker must be invisible over source content")
    }

    func test_snapshotView_withSuperview_returnsMarkerSizedImageView() throws {
        // With a superview, the override must render its own placard (a UIImageView sized to the
        // marker) rather than falling back to the transparent super-snapshot. The captured pixel
        // content requires an on-screen, render-committed view, so it is verified by live QA in the
        // demo, not here — the XCTest harness cannot commit a render pass for a just-added view
        // (see the "not committed to render server" limitation).
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let marker = ZoomSourceMarkerView(frame: CGRect(x: 20, y: 20, width: 40, height: 40))
        container.addSubview(marker)

        let snapshot = try XCTUnwrap(
            marker.snapshotView(afterScreenUpdates: false) as? UIImageView,
            "with a superview the override must return its own rendered UIImageView"
        )
        let image = try XCTUnwrap(snapshot.image, "the render branch must produce an image")
        XCTAssertEqual(image.size, CGSize(width: 40, height: 40), "placard must match the marker's frame size")
    }

    func test_snapshotView_withNoSuperview_doesNotCrash() {
        let marker = ZoomSourceMarkerView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        _ = marker.snapshotView(afterScreenUpdates: false)   // guard path: no superview → super; must not crash
    }
}
