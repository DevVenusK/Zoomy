import XCTest
import CoreGraphics
import ZoomyCore

/// Property-based tests for `ZoomGeometry` pure geometry — invariants that must hold across a
/// large space of randomly generated inputs (in-house runner, no external dependencies).
final class ZoomGeometryPropertyTests: XCTestCase {

    /// Random geometry with non-negative sizes (so mid-transition portal rects stay valid).
    private func randomGeometry(using rng: inout SeededGenerator) -> ZoomGeometry {
        ZoomGeometry(
            sourceRect: CGRect(
                x: randomCGFloat(in: -500...500, using: &rng),
                y: randomCGFloat(in: -500...500, using: &rng),
                width: randomCGFloat(in: 0...1_000, using: &rng),
                height: randomCGFloat(in: 0...1_000, using: &rng)
            ),
            sourceVisibleRect: CGRect(
                x: randomCGFloat(in: -500...500, using: &rng),
                y: randomCGFloat(in: -500...500, using: &rng),
                width: randomCGFloat(in: 0...1_000, using: &rng),
                height: randomCGFloat(in: 0...1_000, using: &rng)
            ),
            finalRect: CGRect(
                x: randomCGFloat(in: -500...500, using: &rng),
                y: randomCGFloat(in: -500...500, using: &rng),
                width: randomCGFloat(in: 0...1_000, using: &rng),
                height: randomCGFloat(in: 0...1_000, using: &rng)
            ),
            sourceCornerRadius: randomCGFloat(in: 0...300, using: &rng),
            finalCornerRadius: randomCGFloat(in: 0...300, using: &rng)
        )
    }

    // MARK: - portalRect endpoints

    func test_property_portalRectAtZero_equalsSourceRect() {
        checkProperty("portalRect(at: 0) == sourceRect", iterations: 1_000) { rng in
            randomGeometry(using: &rng)
        } holds: { geometry in
            geometry.portalRect(at: 0) == geometry.sourceRect
        }
    }

    func test_property_portalRectAtOne_equalsFinalRect() {
        checkProperty("portalRect(at: 1) ≈ finalRect", iterations: 1_000) { rng in
            randomGeometry(using: &rng)
        } holds: { geometry in
            let rect = geometry.portalRect(at: 1)
            let final = geometry.finalRect
            return approxEqual(rect.origin.x, final.origin.x)
                && approxEqual(rect.origin.y, final.origin.y)
                && approxEqual(rect.width, final.width)
                && approxEqual(rect.height, final.height)
        }
    }

    // MARK: - portalRect monotonicity over [0, 1]

    func test_property_portalRect_componentsAreMonotonicOverUnitInterval() {
        checkProperty("portalRect components monotone on [0,1]", iterations: 1_000) { rng -> (ZoomGeometry, CGFloat, CGFloat) in
            let geometry = randomGeometry(using: &rng)
            let a = randomCGFloat(in: 0...1, using: &rng)
            let b = randomCGFloat(in: 0...1, using: &rng)
            return (geometry, min(a, b), max(a, b))
        } holds: { input in
            let (geometry, p1, p2) = input
            let r1 = geometry.portalRect(at: p1)
            let r2 = geometry.portalRect(at: p2)

            func monotone(_ v1: CGFloat, _ v2: CGFloat, source: CGFloat, final: CGFloat) -> Bool {
                let delta = v2 - v1
                if final > source { return delta >= -1e-6 }   // non-decreasing
                if final < source { return delta <= 1e-6 }     // non-increasing
                return approxEqual(v1, v2)                       // constant
            }

            return monotone(r1.origin.x, r2.origin.x, source: geometry.sourceRect.origin.x, final: geometry.finalRect.origin.x)
                && monotone(r1.origin.y, r2.origin.y, source: geometry.sourceRect.origin.y, final: geometry.finalRect.origin.y)
                && monotone(r1.width, r2.width, source: geometry.sourceRect.width, final: geometry.finalRect.width)
                && monotone(r1.height, r2.height, source: geometry.sourceRect.height, final: geometry.finalRect.height)
        }
    }

    // MARK: - cornerRadius bounds

    func test_property_cornerRadius_isWithinRenderableBounds() {
        checkProperty("0 ≤ cornerRadius(at: p) ≤ min(w, h) / 2", iterations: 1_000) { rng -> (ZoomGeometry, CGFloat) in
            (randomGeometry(using: &rng), randomCGFloat(in: 0...1, using: &rng))
        } holds: { input in
            let (geometry, p) = input
            let radius = geometry.cornerRadius(at: p)
            let rect = geometry.portalRect(at: p)
            let maxRadius = min(rect.width, rect.height) / 2
            return radius >= 0 && radius <= maxRadius + 1e-6
        }
    }

    // MARK: - contentScale finiteness / zero-final-width guard

    func test_property_contentScale_isFiniteAndGuardsZeroFinalWidth() {
        checkProperty("contentScale finite; ==1 when finalRect.width == 0", iterations: 1_000) { rng -> (ZoomGeometry, CGFloat) in
            var geometry = randomGeometry(using: &rng)
            // Half the time, force a zero-width final rect to exercise the guard branch.
            if Bool.random(using: &rng) {
                geometry = ZoomGeometry(
                    sourceRect: geometry.sourceRect,
                    sourceVisibleRect: geometry.sourceVisibleRect,
                    finalRect: CGRect(
                        x: geometry.finalRect.origin.x,
                        y: geometry.finalRect.origin.y,
                        width: 0,
                        height: geometry.finalRect.height
                    ),
                    sourceCornerRadius: geometry.sourceCornerRadius,
                    finalCornerRadius: geometry.finalCornerRadius
                )
            }
            let portalWidth = randomCGFloat(in: -1_000...1_000, using: &rng)
            return (geometry, portalWidth)
        } holds: { input in
            let (geometry, portalWidth) = input
            let scale = geometry.contentScale(portalWidth: portalWidth)
            if geometry.finalRect.width == 0 {
                return scale == 1
            }
            return scale.isFinite
        }
    }

    // MARK: - rubberBand

    func test_property_rubberBand_atZeroIsZero() {
        checkProperty("rubberBand(0, d) == 0", iterations: 1_000) { rng in
            randomCGFloat(in: 1...2_000, using: &rng) // dimension
        } holds: { dimension in
            ZoomGeometry.rubberBand(0, dimension: dimension) == 0
        }
    }

    func test_property_rubberBand_preservesSignAndStaysBelowDimension() {
        checkProperty("rubberBand sign-preserving, |out| < dimension", iterations: 1_000) { rng -> (CGFloat, CGFloat) in
            let dimension = randomCGFloat(in: 1...2_000, using: &rng)
            let x = randomCGFloat(in: -5_000...5_000, using: &rng)
            return (x, dimension)
        } holds: { input in
            let (x, dimension) = input
            let out = ZoomGeometry.rubberBand(x, dimension: dimension)
            guard abs(out) < dimension else { return false }
            if x > 0 { return out > 0 }
            if x < 0 { return out < 0 }
            return out == 0
        }
    }

    func test_property_rubberBand_isStrictlyIncreasingInX() {
        checkProperty("rubberBand strictly increasing in x", iterations: 1_000) { rng -> (CGFloat, CGFloat, CGFloat) in
            let dimension = randomCGFloat(in: 1...2_000, using: &rng)
            let x1 = randomCGFloat(in: -5_000...5_000, using: &rng)
            let gap = randomCGFloat(in: 0.5...1_000, using: &rng)
            return (x1, x1 + gap, dimension)
        } holds: { input in
            let (x1, x2, dimension) = input
            return ZoomGeometry.rubberBand(x2, dimension: dimension) > ZoomGeometry.rubberBand(x1, dimension: dimension)
        }
    }
}
