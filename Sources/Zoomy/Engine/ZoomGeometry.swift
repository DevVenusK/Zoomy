import CoreGraphics

/// Pure geometry for a zoom transition portal — no UIKit dependency.
/// All rects are expressed in the shared container's coordinate space.
struct ZoomGeometry: Equatable {
    let sourceRect: CGRect
    let sourceVisibleRect: CGRect
    let finalRect: CGRect
    let sourceCornerRadius: CGFloat
    let finalCornerRadius: CGFloat

    /// Componentwise lerp from `sourceRect` to `finalRect`. `progress` is not clamped so
    /// spring overshoot can extrapolate past the endpoints; callers reverse (1 - p) for zoom-out.
    func portalRect(at progress: CGFloat) -> CGRect {
        CGRect(
            x: Self.lerp(sourceRect.origin.x, finalRect.origin.x, progress),
            y: Self.lerp(sourceRect.origin.y, finalRect.origin.y, progress),
            width: Self.lerp(sourceRect.width, finalRect.width, progress),
            height: Self.lerp(sourceRect.height, finalRect.height, progress)
        )
    }

    /// Lerp from `sourceCornerRadius` to `finalCornerRadius`, then clamp to
    /// `[0, min(portalRect(at: progress) shortest side) / 2]` so the radius never exceeds
    /// what the (possibly tiny, mid-transition) portal rect can actually render.
    func cornerRadius(at progress: CGFloat) -> CGFloat {
        let raw = Self.lerp(sourceCornerRadius, finalCornerRadius, progress)
        let rect = portalRect(at: progress)
        let maxRadius = min(rect.width, rect.height) / 2
        return max(0, min(raw, maxRadius))
    }

    /// = portalWidth / finalRect.width, guarded against a zero-width final rect.
    func contentScale(portalWidth: CGFloat) -> CGFloat {
        guard finalRect.width != 0 else { return 1 }
        return portalWidth / finalRect.width
    }

    /// Diminishing-returns rubber-band resistance, matching the classic
    /// `sign(x) * (1 - 1/(|x|*c/dimension + 1)) * dimension` formula (e.g. UIScrollView bounce).
    static func rubberBand(_ x: CGFloat, dimension: CGFloat, c: CGFloat = 0.55) -> CGFloat {
        guard x != 0 else { return 0 }
        let sign: CGFloat = x < 0 ? -1 : 1
        let magnitude = abs(x)
        return sign * (1 - 1 / (magnitude * c / dimension + 1)) * dimension
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

/// Pure model translating a raw pan-gesture translation/velocity into follow geometry for an
/// interactive zoom dismissal. No UIKit dependency.
struct FollowModel {
    let containerSize: CGSize
    let initialCenter: CGPoint

    static let kX: CGFloat = 0.5
    static let spanRatio: CGFloat = 0.55
    static let scaleRange: CGFloat = 0.45
    static let scaleFloor: CGFloat = 0.55
    static let rampEnd: CGFloat = 0.2
    static let flickVelocity: CGFloat = 500
    static let decelerationRate: CGFloat = 0.998
    static let minDirectionDistance: CGFloat = 10

    var span: CGFloat { Self.spanRatio * containerSize.height }

    /// = clamp((max(t.y, 0) + kX*|t.x|) / span, 0, 1)
    func progress(for translation: CGPoint) -> CGFloat {
        let raw = (max(translation.y, 0) + Self.kX * abs(translation.x)) / span
        return min(max(raw, 0), 1)
    }

    /// = max(scaleFloor, 1 - scaleRange*(1-(1-p)^2))
    func scale(forProgress p: CGFloat) -> CGFloat {
        let remaining = 1 - p
        let raw = 1 - Self.scaleRange * (1 - remaining * remaining)
        return max(Self.scaleFloor, raw)
    }

    func center(for translation: CGPoint) -> CGPoint {
        let y: CGFloat
        if translation.y >= 0 {
            y = initialCenter.y + translation.y
        } else {
            y = initialCenter.y + ZoomGeometry.rubberBand(translation.y, dimension: containerSize.height)
        }
        return CGPoint(x: initialCenter.x + translation.x, y: y)
    }

    /// = min(1, p / rampEnd)
    func cornerProgress(forProgress p: CGFloat) -> CGFloat {
        min(1, p / Self.rampEnd)
    }

    /// Radial-projection flick/settle decision. Projects velocity onto the established drag
    /// direction (falling back to straight-down when the drag is too short to have a reliable
    /// direction), then either decides immediately on a strong flick or extrapolates the
    /// deceleration-scroll-style projected distance to see whether it would cross the midpoint.
    func shouldComplete(progress p: CGFloat, velocity v: CGPoint, translation t: CGPoint) -> Bool {
        let magnitude = (t.x * t.x + t.y * t.y).squareRoot()
        let direction: CGPoint
        if magnitude < Self.minDirectionDistance {
            direction = CGPoint(x: 0, y: 1)
        } else {
            direction = CGPoint(x: t.x / magnitude, y: t.y / magnitude)
        }

        let vR = v.x * direction.x + v.y * direction.y

        if vR > Self.flickVelocity { return true }
        if vR < -Self.flickVelocity { return false }

        let projected = (vR / 1_000) * Self.decelerationRate / (1 - Self.decelerationRate)
        return p + projected / span > 0.5
    }
}

/// §7.7 freeze-and-rebuild 후 진행도→새 애니메이터 fraction 재매핑.
enum AnimatorFractionRemap {
    /// = clamp((p - base) / (1 - base), 0, 0.995); guarded to 0.995 when base >= 1.
    static func remap(progress p: CGFloat, base: CGFloat) -> CGFloat {
        guard base < 1 else { return 0.995 }
        let raw = (p - base) / (1 - base)
        return min(max(raw, 0), 0.995)
    }
}
