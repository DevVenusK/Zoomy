import CoreGraphics

/// Pure geometry for a zoom transition portal — no UIKit dependency.
/// All rects are expressed in the shared container's coordinate space.
public struct ZoomGeometry: Equatable {
    public let sourceRect: CGRect
    public let sourceVisibleRect: CGRect
    public let finalRect: CGRect
    public let sourceCornerRadius: CGFloat
    public let finalCornerRadius: CGFloat

    public init(
        sourceRect: CGRect,
        sourceVisibleRect: CGRect,
        finalRect: CGRect,
        sourceCornerRadius: CGFloat,
        finalCornerRadius: CGFloat
    ) {
        self.sourceRect = sourceRect
        self.sourceVisibleRect = sourceVisibleRect
        self.finalRect = finalRect
        self.sourceCornerRadius = sourceCornerRadius
        self.finalCornerRadius = finalCornerRadius
    }

    /// Componentwise lerp from `sourceRect` to `finalRect`. `progress` is not clamped so
    /// spring overshoot can extrapolate past the endpoints; callers reverse (1 - p) for zoom-out.
    public func portalRect(at progress: CGFloat) -> CGRect {
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
    public func cornerRadius(at progress: CGFloat) -> CGFloat {
        let raw = Self.lerp(sourceCornerRadius, finalCornerRadius, progress)
        let rect = portalRect(at: progress)
        let maxRadius = min(rect.width, rect.height) / 2
        return max(0, min(raw, maxRadius))
    }

    /// = portalWidth / finalRect.width, guarded against a zero-width final rect.
    public func contentScale(portalWidth: CGFloat) -> CGFloat {
        guard finalRect.width != 0 else { return 1 }
        return portalWidth / finalRect.width
    }

    /// Diminishing-returns rubber-band resistance, matching the classic
    /// `sign(x) * (1 - 1/(|x|*c/dimension + 1)) * dimension` formula (e.g. UIScrollView bounce).
    public static func rubberBand(_ x: CGFloat, dimension: CGFloat, c: CGFloat = 0.55) -> CGFloat {
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
public struct FollowModel {
    public let containerSize: CGSize
    public let initialCenter: CGPoint

    public static let kX: CGFloat = 0.5
    public static let spanRatio: CGFloat = 0.55
    public static let scaleRange: CGFloat = 0.45
    public static let scaleFloor: CGFloat = 0.55
    public static let rampEnd: CGFloat = 0.2
    public static let flickVelocity: CGFloat = 500
    public static let decelerationRate: CGFloat = 0.998
    public static let minDirectionDistance: CGFloat = 10

    public init(containerSize: CGSize, initialCenter: CGPoint) {
        self.containerSize = containerSize
        self.initialCenter = initialCenter
    }

    public var span: CGFloat { Self.spanRatio * containerSize.height }

    /// = clamp((max(t.y, 0) + kX*|t.x|) / span, 0, 1)
    public func progress(for translation: CGPoint) -> CGFloat {
        let raw = (max(translation.y, 0) + Self.kX * abs(translation.x)) / span
        return min(max(raw, 0), 1)
    }

    /// = max(scaleFloor, 1 - scaleRange*(1-(1-p)^2))
    public func scale(forProgress p: CGFloat) -> CGFloat {
        let remaining = 1 - p
        let raw = 1 - Self.scaleRange * (1 - remaining * remaining)
        return max(Self.scaleFloor, raw)
    }

    public func center(for translation: CGPoint) -> CGPoint {
        let y: CGFloat
        if translation.y >= 0 {
            y = initialCenter.y + translation.y
        } else {
            y = initialCenter.y + ZoomGeometry.rubberBand(translation.y, dimension: containerSize.height)
        }
        return CGPoint(x: initialCenter.x + translation.x, y: y)
    }

    /// = min(1, p / rampEnd)
    public func cornerProgress(forProgress p: CGFloat) -> CGFloat {
        min(1, p / Self.rampEnd)
    }

    /// Radial-projection flick/settle decision. Projects velocity onto the established drag
    /// direction (falling back to straight-down when the drag is too short to have a reliable
    /// direction), then either decides immediately on a strong flick or extrapolates the
    /// deceleration-scroll-style projected distance to see whether it would cross the midpoint.
    public func shouldComplete(progress p: CGFloat, velocity v: CGPoint, translation t: CGPoint) -> Bool {
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
public enum AnimatorFractionRemap {
    /// = clamp((p - base) / (1 - base), 0, 0.995); guarded to 0.995 when base >= 1.
    public static func remap(progress p: CGFloat, base: CGFloat) -> CGFloat {
        guard base < 1 else { return 0.995 }
        let raw = (p - base) / (1 - base)
        return min(max(raw, 0), 0.995)
    }
}
