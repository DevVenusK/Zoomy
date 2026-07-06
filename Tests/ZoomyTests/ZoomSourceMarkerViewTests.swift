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
}
