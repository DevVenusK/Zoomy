import XCTest
import UIKit
@testable import Zoomy

/// The spec gate for M7 §3 (`docs/TECH_SPEC.md` §7.8): `BarSnapshotController` inserts a faded bar
/// snapshot below the portal, hides the real bar (recorded on the token), and restores it on cleanup;
/// a `nil` snapshot is skipped without crashing. `makeSnapshot` is injected so the install/skip paths
/// are deterministic (`snapshotView` is unreliable for an off-screen bar in a test).
@MainActor
final class BarSnapshotTests: XCTestCase {

    private struct Fixture {
        let container: UIView
        let portal: PortalView
        let tabBar: UITabBar
        let token: RestorationToken
    }

    private func makeFixture() -> Fixture {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let tabBar = UITabBar(frame: CGRect(x: 0, y: 795, width: 390, height: 49))
        container.addSubview(tabBar)
        let portal = PortalView(frame: .zero)
        container.addSubview(portal)
        return Fixture(container: container, portal: portal, tabBar: tabBar, token: RestorationToken())
    }

    // MARK: - Install (push): snapshot inserted below portal, real bar hidden

    func test_install_push_insertsSnapshotBelowPortal_andHidesRealBar() {
        let fx = makeFixture()
        let controller = BarSnapshotController()
        let dummySnapshot = UIView()
        controller.makeSnapshot = { _ in dummySnapshot }

        let installed = controller.install(
            phase: .appearing,
            container: fx.container,
            tabBar: fx.tabBar,
            toolbar: nil,
            belowPortal: fx.portal,
            token: fx.token
        )

        XCTAssertTrue(installed)
        XCTAssertEqual(controller.snapshots.count, 1)
        XCTAssertTrue(dummySnapshot.superview === fx.container, "snapshot must be added to the container")
        // Below the portal in z-order.
        let snapshotIndex = fx.container.subviews.firstIndex(of: dummySnapshot)!
        let portalIndex = fx.container.subviews.firstIndex(of: fx.portal)!
        XCTAssertLessThan(snapshotIndex, portalIndex, "snapshot must sit below the portal")
        // Snapshot starts visible (push fades it out); real bar hidden.
        XCTAssertEqual(dummySnapshot.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(fx.tabBar.alpha, 0, accuracy: 0.001, "the real bar must be hidden during the flight")
        // Frame positioned at the bar's on-screen rect.
        XCTAssertEqual(dummySnapshot.frame, fx.container.convert(fx.tabBar.bounds, from: fx.tabBar))
    }

    // MARK: - Install (pop): snapshot starts hidden (fades in)

    func test_install_pop_snapshotStartsHidden() {
        let fx = makeFixture()
        let controller = BarSnapshotController()
        let dummySnapshot = UIView()
        controller.makeSnapshot = { _ in dummySnapshot }

        controller.install(
            phase: .disappearing, container: fx.container, tabBar: fx.tabBar,
            toolbar: nil, belowPortal: fx.portal, token: fx.token
        )
        XCTAssertEqual(dummySnapshot.alpha, 0, accuracy: 0.001, "on a pop the snapshot fades in from 0")
        XCTAssertEqual(fx.tabBar.alpha, 0, accuracy: 0.001)
    }

    // MARK: - Cleanup restores the real bar alpha (token) and removes the snapshot

    func test_cleanup_restoresRealBarAlphaAndRemovesSnapshot() {
        let fx = makeFixture()
        let controller = BarSnapshotController()
        let dummySnapshot = UIView()
        controller.makeSnapshot = { _ in dummySnapshot }

        controller.install(
            phase: .appearing, container: fx.container, tabBar: fx.tabBar,
            toolbar: nil, belowPortal: fx.portal, token: fx.token
        )
        XCTAssertEqual(fx.tabBar.alpha, 0, accuracy: 0.001)

        // The driver removes snapshots and restores the token in cleanup.
        controller.removeSnapshots()
        fx.token.restore()

        XCTAssertEqual(fx.tabBar.alpha, 1, accuracy: 0.001, "the real bar alpha must be restored")
        XCTAssertNil(dummySnapshot.superview, "the snapshot must be removed")
        XCTAssertTrue(controller.snapshots.isEmpty)
    }

    // MARK: - Nil snapshot is skipped without crashing

    func test_install_nilSnapshot_isSkippedAndLeavesRealBarUntouched() {
        let fx = makeFixture()
        let controller = BarSnapshotController()
        controller.makeSnapshot = { _ in nil }

        let installed = controller.install(
            phase: .appearing, container: fx.container, tabBar: fx.tabBar,
            toolbar: nil, belowPortal: fx.portal, token: fx.token
        )

        XCTAssertFalse(installed, "a nil snapshot installs nothing")
        XCTAssertTrue(controller.snapshots.isEmpty)
        XCTAssertEqual(fx.tabBar.alpha, 1, accuracy: 0.001, "the real bar must be left untouched")
    }

    // MARK: - No bars at all: no-op

    func test_install_noBars_isNoOp() {
        let fx = makeFixture()
        let controller = BarSnapshotController()
        let installed = controller.install(
            phase: .appearing, container: fx.container, tabBar: nil,
            toolbar: nil, belowPortal: fx.portal, token: fx.token
        )
        XCTAssertFalse(installed)
        XCTAssertTrue(controller.snapshots.isEmpty)
    }

    // MARK: - Fade targets

    func test_addFade_push_fadesSnapshotToZero() {
        let fx = makeFixture()
        let controller = BarSnapshotController()
        let dummySnapshot = UIView()
        controller.makeSnapshot = { _ in dummySnapshot }
        controller.install(
            phase: .appearing, container: fx.container, tabBar: fx.tabBar,
            toolbar: nil, belowPortal: fx.portal, token: fx.token
        )

        let animator = UIViewPropertyAnimator(duration: 0.1, curve: .linear)
        controller.addFade(to: animator, phase: .appearing)
        animator.startAnimation()
        animator.stopAnimation(false)
        animator.finishAnimation(at: .end)

        XCTAssertEqual(dummySnapshot.alpha, 0, accuracy: 0.001, "a push fades the snapshot out")
    }
}
