import UIKit

/// Fades a tab bar / toolbar across a push/pop that hides the bottom bar
/// (`hidesBottomBarWhenPushed`), so the bar doesn't pop in/out abruptly (`docs/TECH_SPEC.md` §7.8).
///
/// The mechanic: snapshot the live bar, insert the snapshot into the transition container at the
/// bar's on-screen position (below the portal), hide the real bar (`alpha = 0`, recorded on the
/// `RestorationToken` so `cleanup` restores it), and let the transition animator fade the snapshot —
/// out on the way in (push), in on the way out (pop). A `nil` snapshot skips that bar entirely (never
/// crashes).
///
/// Navigation-bar snapshotting for the "both bars visible" case is out of scope (README caveat, M8):
/// the recommended pattern is for the pushed detail to hide the nav bar (the Example does this).
@MainActor
final class BarSnapshotController {

    /// How a bar is snapshotted. Overridable so a test can drive the install/skip paths
    /// deterministically (`snapshotView` is unreliable for an off-screen view).
    var makeSnapshot: (UIView) -> UIView? = { $0.snapshotView(afterScreenUpdates: false) }

    /// The snapshot views inserted into the container, faded by the transition animator and removed
    /// by `removeSnapshots`.
    private(set) var snapshots: [UIView] = []

    /// Inserts a faded snapshot for each supplied bar below `portal`, recording+zeroing the real bar's
    /// alpha on `token`. Returns whether any snapshot was installed. Pass only the bars that should
    /// disappear (the driver gates `tabBar` on `hidesBottomBarWhenPushed`); a `nil` bar or a `nil`
    /// snapshot is silently skipped.
    @discardableResult
    func install(
        phase: ZoomTransition.Phase,
        container: UIView,
        tabBar: UITabBar?,
        toolbar: UIToolbar?,
        belowPortal portal: UIView,
        token: RestorationToken
    ) -> Bool {
        for bar in [tabBar as UIView?, toolbar as UIView?].compactMap({ $0 }) {
            guard let snapshot = makeSnapshot(bar) else { continue }
            snapshot.frame = container.convert(bar.bounds, from: bar)
            // Snapshot starts where the real bar is: visible for a push (fades out), hidden for a pop
            // (fades in). The real bar is hidden for the whole flight and restored by the token.
            snapshot.alpha = (phase == .appearing) ? 1 : 0
            token.recordAlpha(of: bar)
            bar.alpha = 0
            if portal.superview === container {
                container.insertSubview(snapshot, belowSubview: portal)
            } else {
                container.addSubview(snapshot)
            }
            snapshots.append(snapshot)
        }
        return !snapshots.isEmpty
    }

    /// Adds the snapshot alpha fade to the transition animator: out over a push, in over a pop.
    func addFade(to transitionAnimator: UIViewPropertyAnimator, phase: ZoomTransition.Phase) {
        guard !snapshots.isEmpty else { return }
        let targetAlpha: CGFloat = (phase == .appearing) ? 0 : 1
        let snapshots = self.snapshots
        transitionAnimator.addAnimations {
            for snapshot in snapshots { snapshot.alpha = targetAlpha }
        }
    }

    /// Removes the inserted snapshots. Called from `cleanup` (the token restores the real bars).
    func removeSnapshots() {
        for snapshot in snapshots { snapshot.removeFromSuperview() }
        snapshots.removeAll()
    }
}
