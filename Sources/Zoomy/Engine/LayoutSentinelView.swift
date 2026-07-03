import UIKit

/// An invisible, non-interactive view pinned to fill the transition container, used purely to detect
/// a container **bounds change** (rotation / split-view resize) during a push/pop so the driver can
/// `forceFinish(.sizeChange)` — without swizzling or KVO (`docs/TECH_SPEC.md` §7.10).
///
/// A truly zero-size view's `layoutSubviews` would not fire on a container resize (its own bounds
/// never change), so the sentinel instead fills the container via an autoresizing mask: when the
/// container resizes, the mask resizes the sentinel, which fires `layoutSubviews`, where we compare
/// against the last seen size and invoke `onContainerBoundsChange`. It draws nothing and takes no
/// touches, so it is visually and behaviourally inert.
final class LayoutSentinelView: UIView {

    /// Invoked from `layoutSubviews` when the sentinel's size (i.e. the container's) actually changes
    /// after the first layout pass. Never fired for the initial sizing.
    var onContainerBoundsChange: (() -> Void)?

    private var lastSize: CGSize?

    init(frame: CGRect, onContainerBoundsChange: @escaping () -> Void) {
        self.onContainerBoundsChange = onContainerBoundsChange
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = false
        backgroundColor = .clear
        isAccessibilityElement = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard let lastSize else {
            self.lastSize = size
            return
        }
        guard size != lastSize else { return }
        self.lastSize = size
        // Retain across the callback: forceFinish's cleanup removes and releases this sentinel, and
        // deallocating mid-`layoutSubviews` would be a use-after-free.
        withExtendedLifetime(self) {
            onContainerBoundsChange?()
        }
    }
}
