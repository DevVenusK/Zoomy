import XCTest
import CoreGraphics
import ZoomyCore

/// Property-based tests for `FollowModel` interactive-dismissal geometry.
final class FollowModelPropertyTests: XCTestCase {

    /// Random model with a strictly positive container height (so `span > 0`).
    private func randomModel(using rng: inout SeededGenerator) -> FollowModel {
        FollowModel(
            containerSize: CGSize(
                width: randomCGFloat(in: 1...1_200, using: &rng),
                height: randomCGFloat(in: 1...1_200, using: &rng)
            ),
            initialCenter: randomPoint(x: -500...500, y: -500...500, using: &rng)
        )
    }

    // MARK: - progress

    func test_property_progress_isClampedToUnitInterval() {
        checkProperty("progress ∈ [0, 1]", iterations: 1_000) { rng -> (FollowModel, CGPoint) in
            (randomModel(using: &rng), randomPoint(x: -5_000...5_000, y: -5_000...5_000, using: &rng))
        } holds: { input in
            let (model, translation) = input
            let p = model.progress(for: translation)
            return p >= 0 && p <= 1
        }
    }

    func test_property_progress_isMonotonicInDownwardTranslation() {
        checkProperty("progress non-decreasing as downward t.y grows", iterations: 1_000) { rng -> (FollowModel, CGFloat, CGFloat, CGFloat) in
            let model = randomModel(using: &rng)
            let x = randomCGFloat(in: -2_000...2_000, using: &rng)
            let y1 = randomCGFloat(in: 0...3_000, using: &rng)
            let gap = randomCGFloat(in: 0...3_000, using: &rng)
            return (model, x, y1, y1 + gap)
        } holds: { input in
            let (model, x, y1, y2) = input
            let p1 = model.progress(for: CGPoint(x: x, y: y1))
            let p2 = model.progress(for: CGPoint(x: x, y: y2))
            return p2 >= p1 - 1e-6
        }
    }

    // MARK: - scale

    func test_property_scale_isWithinFloorAndOne() {
        checkProperty("scale ∈ [scaleFloor, 1]", iterations: 1_000) { rng -> (FollowModel, CGFloat) in
            (randomModel(using: &rng), randomCGFloat(in: 0...1, using: &rng))
        } holds: { input in
            let (model, p) = input
            let scale = model.scale(forProgress: p)
            return scale >= FollowModel.scaleFloor - 1e-6 && scale <= 1 + 1e-6
        }
    }

    func test_property_scale_isMonotonicNonIncreasingInProgress() {
        checkProperty("scale non-increasing as progress grows", iterations: 1_000) { rng -> (FollowModel, CGFloat, CGFloat) in
            let model = randomModel(using: &rng)
            let a = randomCGFloat(in: 0...1, using: &rng)
            let b = randomCGFloat(in: 0...1, using: &rng)
            return (model, min(a, b), max(a, b))
        } holds: { input in
            let (model, p1, p2) = input
            return model.scale(forProgress: p1) >= model.scale(forProgress: p2) - 1e-6
        }
    }

    // MARK: - cornerProgress

    func test_property_cornerProgress_isClampedToUnitInterval() {
        checkProperty("cornerProgress ∈ [0, 1]", iterations: 1_000) { rng -> (FollowModel, CGFloat) in
            (randomModel(using: &rng), randomCGFloat(in: 0...5, using: &rng))
        } holds: { input in
            let (model, p) = input
            let cp = model.cornerProgress(forProgress: p)
            return cp >= 0 && cp <= 1
        }
    }

    // MARK: - center

    func test_property_center_xIsInitialPlusTranslationX() {
        checkProperty("center(for: t).x == initialCenter.x + t.x", iterations: 1_000) { rng -> (FollowModel, CGPoint) in
            (randomModel(using: &rng), randomPoint(x: -3_000...3_000, y: -3_000...3_000, using: &rng))
        } holds: { input in
            let (model, translation) = input
            return model.center(for: translation).x == model.initialCenter.x + translation.x
        }
    }
}
