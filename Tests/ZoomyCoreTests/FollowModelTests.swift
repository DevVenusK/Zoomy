import XCTest
import CoreGraphics
import ZoomyCore

final class FollowModelTests: XCTestCase {

    private let containerSize = CGSize(width: 300, height: 800) // span = 0.55 * 800 = 440
    private let initialCenter = CGPoint(x: 50, y: 50)

    private func makeModel() -> FollowModel {
        FollowModel(containerSize: containerSize, initialCenter: initialCenter)
    }

    // MARK: - progress(for:)

    func test_progress_verticalOnly() {
        let model = makeModel()
        // (max(220, 0) + 0.5*0) / 440 = 0.5
        XCTAssertEqual(model.progress(for: CGPoint(x: 0, y: 220)), 0.5, accuracy: 0.0001)
    }

    func test_progress_horizontalOnly_reflectsKXWeighting() {
        let model = makeModel()
        // (0 + 0.5*220) / 440 = 0.25
        XCTAssertEqual(model.progress(for: CGPoint(x: 220, y: 0)), 0.25, accuracy: 0.0001)
    }

    func test_progress_diagonal() {
        let model = makeModel()
        // (150 + 0.5*100) / 440 = 200/440
        let expected: CGFloat = 200.0 / 440.0
        XCTAssertEqual(model.progress(for: CGPoint(x: 100, y: 150)), expected, accuracy: 0.0001)
    }

    func test_progress_negativeY_contributesZero() {
        let model = makeModel()
        XCTAssertEqual(model.progress(for: CGPoint(x: 0, y: -300)), 0, accuracy: 0.0001)
    }

    func test_progress_negativeYWithHorizontal_onlyHorizontalContributes() {
        let model = makeModel()
        // max(-300, 0) + 0.5*100 = 50; 50/440
        let expected: CGFloat = 50.0 / 440.0
        XCTAssertEqual(model.progress(for: CGPoint(x: 100, y: -300)), expected, accuracy: 0.0001)
    }

    func test_progress_isClampedToOne() {
        let model = makeModel()
        XCTAssertEqual(model.progress(for: CGPoint(x: 0, y: 5_000)), 1, accuracy: 0.0001)
    }

    // MARK: - scale(forProgress:)

    func test_scale_atZero_isOne() {
        let model = makeModel()
        XCTAssertEqual(model.scale(forProgress: 0), 1, accuracy: 0.0001)
    }

    func test_scale_atOne_reachesFloor() {
        let model = makeModel()
        XCTAssertEqual(model.scale(forProgress: 1), 0.55, accuracy: 0.0001)
    }

    func test_scale_atHalf_isBetweenOneAndFloor() {
        let model = makeModel()
        // 1 - 0.45*(1-0.25) = 0.6625
        XCTAssertEqual(model.scale(forProgress: 0.5), 0.6625, accuracy: 0.0001)
    }

    func test_scale_neverGoesBelowFloor() {
        let model = makeModel()
        for p: CGFloat in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertGreaterThanOrEqual(model.scale(forProgress: p), 0.55 - 0.0001)
        }
    }

    // MARK: - center(for:)

    func test_center_downwardTranslation_movesLinearly() {
        let model = makeModel()
        let result = model.center(for: CGPoint(x: 20, y: 120))
        XCTAssertEqual(result.x, initialCenter.x + 20, accuracy: 0.0001)
        XCTAssertEqual(result.y, initialCenter.y + 120, accuracy: 0.0001)
    }

    func test_center_upwardTranslation_usesRubberBandOnY() {
        let model = makeModel()
        let translation = CGPoint(x: 0, y: -100)
        let result = model.center(for: translation)

        XCTAssertEqual(result.x, initialCenter.x, accuracy: 0.0001)

        let expectedRubberBand = ZoomGeometry.rubberBand(translation.y, dimension: containerSize.height)
        XCTAssertEqual(result.y, initialCenter.y + expectedRubberBand, accuracy: 0.0001)

        // Resistance: rubber-banded offset should be less extreme than the raw translation,
        // but should still move upward from the initial center.
        XCTAssertGreaterThan(result.y, initialCenter.y + translation.y)
        XCTAssertLessThan(result.y, initialCenter.y)
    }

    // MARK: - cornerProgress(forProgress:)

    func test_cornerProgress_reachesOneAtRampEnd() {
        let model = makeModel()
        XCTAssertEqual(model.cornerProgress(forProgress: 0.2), 1, accuracy: 0.0001)
    }

    func test_cornerProgress_isHalfwayAtHalfRampEnd() {
        let model = makeModel()
        XCTAssertEqual(model.cornerProgress(forProgress: 0.1), 0.5, accuracy: 0.0001)
    }

    func test_cornerProgress_isClampedPastRampEnd() {
        let model = makeModel()
        XCTAssertEqual(model.cornerProgress(forProgress: 0.6), 1, accuracy: 0.0001)
    }

    func test_cornerProgress_atZero_isZero() {
        let model = makeModel()
        XCTAssertEqual(model.cornerProgress(forProgress: 0), 0, accuracy: 0.0001)
    }

    // MARK: - shouldComplete(progress:velocity:translation:)

    func test_shouldComplete_downwardFlick_completes() {
        let model = makeModel()
        let result = model.shouldComplete(
            progress: 0.3,
            velocity: CGPoint(x: 0, y: 600),
            translation: CGPoint(x: 0, y: 50)
        )
        XCTAssertTrue(result)
    }

    func test_shouldComplete_upwardFlickAgainstDownwardDrag_cancels() {
        let model = makeModel()
        // Dragged down (translation direction established as downward), then flicked back up fast:
        // radial projection onto the drag direction is strongly negative -> cancel.
        let result = model.shouldComplete(
            progress: 0.3,
            velocity: CGPoint(x: 0, y: -600),
            translation: CGPoint(x: 0, y: 50)
        )
        XCTAssertFalse(result)
    }

    func test_shouldComplete_sidewaysFlick_completes() {
        // Spec example: radial projection makes a sideways dismiss flick register as completion.
        let model = makeModel()
        let result = model.shouldComplete(
            progress: 0.3,
            velocity: CGPoint(x: 2_000, y: 0),
            translation: CGPoint(x: 300, y: 5)
        )
        XCTAssertTrue(result)
    }

    func test_shouldComplete_lowSpeedBoundary_projectedCrossesHalf() {
        let model = makeModel()
        let result = model.shouldComplete(
            progress: 0.4,
            velocity: CGPoint(x: 0, y: 100),
            translation: CGPoint(x: 0, y: 50)
        )
        XCTAssertTrue(result)
    }

    func test_shouldComplete_lowSpeedBoundary_projectedStaysBelowHalf() {
        let model = makeModel()
        let result = model.shouldComplete(
            progress: 0.4,
            velocity: CGPoint(x: 0, y: 50),
            translation: CGPoint(x: 0, y: 50)
        )
        XCTAssertFalse(result)
    }

    func test_shouldComplete_translationBelowMinDistance_fallsBackToDownwardDirection() {
        let model = makeModel()
        // translation magnitude (9) is below minDirectionDistance (10), so direction must fall
        // back to (0, 1) rather than normalizing the (nearly horizontal) raw translation.
        // With the fallback, a purely-horizontal velocity contributes zero to vR.
        let result = model.shouldComplete(
            progress: 0.3,
            velocity: CGPoint(x: 600, y: 0),
            translation: CGPoint(x: 9, y: 0)
        )
        XCTAssertFalse(result)
    }
}

final class AnimatorFractionRemapTests: XCTestCase {

    func test_remap_baseZero() {
        XCTAssertEqual(AnimatorFractionRemap.remap(progress: 0.3, base: 0), 0.3, accuracy: 0.0001)
    }

    func test_remap_baseHalf() {
        XCTAssertEqual(AnimatorFractionRemap.remap(progress: 0.75, base: 0.5), 0.5, accuracy: 0.0001)
    }

    func test_remap_baseOne_guardsDivisionByZero() {
        XCTAssertEqual(AnimatorFractionRemap.remap(progress: 0.9, base: 1.0), 0.995, accuracy: 0.0001)
    }

    func test_remap_baseAboveOne_stillGuarded() {
        XCTAssertEqual(AnimatorFractionRemap.remap(progress: 0.9, base: 1.2), 0.995, accuracy: 0.0001)
    }

    func test_remap_progressBelowBase_clampsToZero() {
        XCTAssertEqual(AnimatorFractionRemap.remap(progress: 0.2, base: 0.5), 0, accuracy: 0.0001)
    }

    func test_remap_upperBoundIsCappedAt0995() {
        XCTAssertEqual(AnimatorFractionRemap.remap(progress: 0.999, base: 0), 0.995, accuracy: 0.0001)
    }
}
