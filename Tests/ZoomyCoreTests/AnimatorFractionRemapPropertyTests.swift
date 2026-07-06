import XCTest
import CoreGraphics
import ZoomyCore

/// Property-based tests for `AnimatorFractionRemap.remap` (freeze-and-rebuild progress remap).
final class AnimatorFractionRemapPropertyTests: XCTestCase {

    // MARK: - range

    func test_property_remap_isWithinZeroTo0995() {
        checkProperty("remap ∈ [0, 0.995]", iterations: 1_000) { rng -> (CGFloat, CGFloat) in
            (randomCGFloat(in: -0.5...1.5, using: &rng), randomCGFloat(in: -0.5...1.5, using: &rng))
        } holds: { input in
            let (p, base) = input
            let r = AnimatorFractionRemap.remap(progress: p, base: base)
            return r >= 0 && r <= 0.995
        }
    }

    // MARK: - p ≤ base ⇒ 0  (for base < 1)

    func test_property_remap_progressBelowBase_isZero() {
        checkProperty("p ≤ base ⇒ remap == 0 (base < 1)", iterations: 1_000) { rng -> (CGFloat, CGFloat) in
            let base = randomCGFloat(in: 0...0.99, using: &rng)
            let delta = randomCGFloat(in: 0...2, using: &rng) // p = base - delta ≤ base
            return (base - delta, base)
        } holds: { input in
            let (p, base) = input
            return AnimatorFractionRemap.remap(progress: p, base: base) == 0
        }
    }

    // MARK: - monotonic in p (base fixed)

    func test_property_remap_isMonotonicNonDecreasingInProgress() {
        checkProperty("remap non-decreasing as p grows (base fixed)", iterations: 1_000) { rng -> (CGFloat, CGFloat, CGFloat) in
            let base = randomCGFloat(in: -0.5...1.5, using: &rng)
            let a = randomCGFloat(in: -0.5...1.5, using: &rng)
            let b = randomCGFloat(in: -0.5...1.5, using: &rng)
            return (min(a, b), max(a, b), base)
        } holds: { input in
            let (p1, p2, base) = input
            return AnimatorFractionRemap.remap(progress: p2, base: base)
                >= AnimatorFractionRemap.remap(progress: p1, base: base) - 1e-9
        }
    }

    // MARK: - base ≥ 1 ⇒ 0.995

    func test_property_remap_baseAtOrAboveOne_isCapValue() {
        checkProperty("base ≥ 1 ⇒ remap == 0.995", iterations: 1_000) { rng -> (CGFloat, CGFloat) in
            (randomCGFloat(in: -0.5...1.5, using: &rng), randomCGFloat(in: 1...5, using: &rng))
        } holds: { input in
            let (p, base) = input
            return AnimatorFractionRemap.remap(progress: p, base: base) == 0.995
        }
    }
}
