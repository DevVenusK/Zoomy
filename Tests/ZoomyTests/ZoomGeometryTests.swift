import XCTest
import CoreGraphics
@testable import Zoomy

final class ZoomGeometryTests: XCTestCase {

    private func makeGeometry(
        sourceRect: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        sourceVisibleRect: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        finalRect: CGRect = CGRect(x: 0, y: 0, width: 300, height: 400),
        sourceCornerRadius: CGFloat = 8,
        finalCornerRadius: CGFloat = 0
    ) -> ZoomGeometry {
        ZoomGeometry(
            sourceRect: sourceRect,
            sourceVisibleRect: sourceVisibleRect,
            finalRect: finalRect,
            sourceCornerRadius: sourceCornerRadius,
            finalCornerRadius: finalCornerRadius
        )
    }

    // MARK: - portalRect

    func test_portalRect_atZero_equalsSourceRect() {
        let geometry = makeGeometry()
        XCTAssertEqual(geometry.portalRect(at: 0), geometry.sourceRect)
    }

    func test_portalRect_atOne_equalsFinalRect() {
        let geometry = makeGeometry()
        XCTAssertEqual(geometry.portalRect(at: 1), geometry.finalRect)
    }

    func test_portalRect_atHalf_isComponentwiseMidpoint() {
        let geometry = makeGeometry(
            sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            finalRect: CGRect(x: 200, y: 300, width: 300, height: 500)
        )
        let expected = CGRect(x: 100, y: 150, width: 200, height: 300)
        XCTAssertEqual(geometry.portalRect(at: 0.5), expected)
    }

    func test_portalRect_overshootPastOne_extrapolatesLinearly() {
        let geometry = makeGeometry(
            sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            finalRect: CGRect(x: 100, y: 100, width: 200, height: 200)
        )
        // lerp(a, b, 1.15) = a + 1.15*(b - a)
        let expected = CGRect(
            x: 0 + 1.15 * 100,
            y: 0 + 1.15 * 100,
            width: 100 + 1.15 * 100,
            height: 100 + 1.15 * 100
        )
        let result = geometry.portalRect(at: 1.15)
        XCTAssertEqual(result.origin.x, expected.origin.x, accuracy: 0.0001)
        XCTAssertEqual(result.origin.y, expected.origin.y, accuracy: 0.0001)
        XCTAssertEqual(result.width, expected.width, accuracy: 0.0001)
        XCTAssertEqual(result.height, expected.height, accuracy: 0.0001)
    }

    // MARK: - cornerRadius

    func test_cornerRadius_atZero_equalsSourceCornerRadius() {
        let geometry = makeGeometry(sourceCornerRadius: 8, finalCornerRadius: 20)
        XCTAssertEqual(geometry.cornerRadius(at: 0), 8, accuracy: 0.0001)
    }

    func test_cornerRadius_atOne_equalsFinalCornerRadius() {
        let geometry = makeGeometry(sourceCornerRadius: 8, finalCornerRadius: 20)
        XCTAssertEqual(geometry.cornerRadius(at: 1), 20, accuracy: 0.0001)
    }

    func test_cornerRadius_isClampedToHalfOfPortalRectMinSide() {
        // At progress 0 the portal rect is the tiny sourceRect (10x10), so the naive lerp
        // radius (50) must be clamped down to min-side/2 = 5.
        let geometry = makeGeometry(
            sourceRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            finalRect: CGRect(x: 0, y: 0, width: 400, height: 400),
            sourceCornerRadius: 50,
            finalCornerRadius: 50
        )
        XCTAssertEqual(geometry.cornerRadius(at: 0), 5, accuracy: 0.0001)
    }

    func test_cornerRadius_neverNegative() {
        let geometry = makeGeometry(sourceCornerRadius: 0, finalCornerRadius: 0)
        XCTAssertGreaterThanOrEqual(geometry.cornerRadius(at: 0.5), 0)
    }

    // MARK: - contentScale

    func test_contentScale_isPortalWidthOverFinalWidth() {
        let geometry = makeGeometry(finalRect: CGRect(x: 0, y: 0, width: 300, height: 400))
        XCTAssertEqual(geometry.contentScale(portalWidth: 150), 0.5, accuracy: 0.0001)
    }

    func test_contentScale_guardsAgainstZeroFinalWidth() {
        let geometry = makeGeometry(finalRect: CGRect(x: 0, y: 0, width: 0, height: 400))
        XCTAssertEqual(geometry.contentScale(portalWidth: 150), 1, accuracy: 0.0001)
    }

    // MARK: - rubberBand

    func test_rubberBand_atZero_isZero() {
        XCTAssertEqual(ZoomGeometry.rubberBand(0, dimension: 200), 0, accuracy: 0.0001)
    }

    func test_rubberBand_preservesSign_positive() {
        XCTAssertGreaterThan(ZoomGeometry.rubberBand(50, dimension: 200), 0)
    }

    func test_rubberBand_preservesSign_negative() {
        XCTAssertLessThan(ZoomGeometry.rubberBand(-50, dimension: 200), 0)
    }

    func test_rubberBand_magnitudeNeverReachesDimension() {
        for x: CGFloat in [10, 100, 1_000, 100_000] {
            let result = ZoomGeometry.rubberBand(x, dimension: 200)
            XCTAssertLessThan(abs(result), 200)
        }
    }

    func test_rubberBand_isMonotonicIncreasingInX() {
        let xs: [CGFloat] = [-500, -100, -50, -10, 0, 10, 50, 100, 500]
        let values = xs.map { ZoomGeometry.rubberBand($0, dimension: 200) }
        for i in 1..<values.count {
            XCTAssertGreaterThan(values[i], values[i - 1], "rubberBand should be strictly increasing in x")
        }
    }
}
