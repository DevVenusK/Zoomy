import XCTest
import UIKit
@testable import Zoomy

/// The spec gate for M4's proxy (brief §4): the delegate-forwarding matrix, post-hoc downstream
/// replacement (capability-cache invalidation), the nil / deallocated downstream safety behaviour,
/// and the forwarding-cycle guard.
@MainActor
final class DelegateForwardingTests: XCTestCase {

    private var savedAssertHandler: (@MainActor (String) -> Void)!

    override func setUp() {
        super.setUp()
        savedAssertHandler = ZoomyAssert.handler
    }

    override func tearDown() {
        ZoomyAssert.handler = savedAssertHandler
        super.tearDown()
    }

    // MARK: - Test doubles

    /// Records the delegate messages it receives. Implements two *forwarded-only* optional methods
    /// (`supportedInterfaceOrientations`, `preferredInterfaceOrientationForPresentation`) plus
    /// `willShow`/`didShow` (which the proxy implements itself and then hands off).
    private final class SpyDelegate: NSObject, UINavigationControllerDelegate {
        private(set) var willShowCount = 0
        private(set) var didShowCount = 0
        private(set) var supportedOrientationsCount = 0
        var orientationMask: UIInterfaceOrientationMask = .landscape

        func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
            willShowCount += 1
        }
        func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
            didShowCount += 1
        }
        func navigationControllerSupportedInterfaceOrientations(_ navigationController: UINavigationController) -> UIInterfaceOrientationMask {
            supportedOrientationsCount += 1
            return orientationMask
        }
    }

    private final class DummyAnimator: NSObject, UIViewControllerAnimatedTransitioning {
        func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0 }
        func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {}
    }

    /// A downstream that implements only `willShow`/`didShow` and deliberately does *not* implement
    /// `navigationControllerSupportedInterfaceOrientations` — so it has strictly fewer capabilities
    /// than `SpyDelegate`, which is what the capability-cache-invalidation test hinges on.
    private final class PlainDownstream: NSObject, UINavigationControllerDelegate {
        private(set) var willShowCount = 0
        private(set) var didShowCount = 0
        func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
            willShowCount += 1
        }
        func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
            didShowCount += 1
        }
    }

    private let nav = UINavigationController()

    private var supportedOrientationsSelector: Selector {
        #selector(UINavigationControllerDelegate.navigationControllerSupportedInterfaceOrientations(_:))
    }

    // MARK: - Forwarding matrix

    func test_optionalMethodImplementedOnlyByDownstream_isForwarded() {
        let spy = SpyDelegate()
        spy.orientationMask = .portrait
        let proxy = ZoomNavigationDelegate(forwardingTo: spy)

        XCTAssertTrue(proxy.responds(to: supportedOrientationsSelector),
                      "the proxy must report responding to a selector its downstream implements")

        let mask = (proxy as any UINavigationControllerDelegate)
            .navigationControllerSupportedInterfaceOrientations?(nav)

        XCTAssertEqual(spy.supportedOrientationsCount, 1, "the call must reach the downstream")
        XCTAssertEqual(mask, .portrait, "the downstream's return value must flow back through the proxy")
    }

    func test_willShowAndDidShow_areForwardedToDownstream() {
        let spy = SpyDelegate()
        let proxy = ZoomNavigationDelegate(forwardingTo: spy)

        proxy.navigationController(nav, willShow: UIViewController(), animated: true)
        proxy.navigationController(nav, didShow: UIViewController(), animated: false)

        XCTAssertEqual(spy.willShowCount, 1, "the proxy's own willShow must hand off to the downstream")
        XCTAssertEqual(spy.didShowCount, 1, "the proxy's own didShow must hand off to the downstream")
    }

    // MARK: - Post-hoc downstream replacement (capability-cache invalidation)

    /// The brief's core bug, gated through a *live* navigation controller so UIKit — not the test —
    /// originates the delegate query.
    ///
    /// `A` (old downstream) does NOT implement `navigationControllerSupportedInterfaceOrientations`;
    /// `B` (new downstream) does. UIKit caches "this delegate provides no orientation" from when the
    /// delegate was set with `A`. Reading `nav.supportedInterfaceOrientations` is a UIKit-originated
    /// call routed through that cache — it can only reach `B` if `downstream`'s setter invalidated
    /// the cache by re-assigning `nav.delegate`. Dispatching straight at the proxy (the previous
    /// version of this test) bypassed the cache and so failed to gate the bug; emptying
    /// `invalidateDelegateCapabilityCache()` now turns this test red (verified — see report Fix round 1).
    func test_replacingDownstream_onLiveNav_invalidatesCapabilityCache() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let navController = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let proxy = navController.enableZoomTransitions()

        // A has no orientation opinion — prime UIKit's capability cache while it is the downstream.
        let a = PlainDownstream()
        proxy.downstream = a
        _ = navController.supportedInterfaceOrientations

        // B does have one. The swap must invalidate the cache so UIKit re-queries and honours B.
        let b = SpyDelegate()
        b.orientationMask = .landscapeLeft
        proxy.downstream = b

        XCTAssertTrue(navController.delegate === proxy,
                      "the proxy must stay installed as the delegate after the swap")

        // UIKit-originated query through nav.delegate (NOT a direct dispatch at the proxy).
        let orientations = navController.supportedInterfaceOrientations
        XCTAssertEqual(orientations, .landscapeLeft,
                       "UIKit must honour the new downstream's orientation — only true if the capability cache was invalidated")
        XCTAssertGreaterThanOrEqual(b.supportedOrientationsCount, 1,
                                    "the UIKit-originated call must reach the new downstream")

        // And a hand-off call still routes to the new downstream, not the old one.
        proxy.navigationController(navController, willShow: UIViewController(), animated: true)
        XCTAssertEqual(b.willShowCount, 1, "hand-off must reach the new downstream")
        XCTAssertEqual(a.willShowCount, 0, "the replaced downstream must receive nothing after the swap")
    }

    // MARK: - nil downstream

    func test_nilDownstream_directMethodsAreNilSafe_andRespondsIsFalseForDownstreamOnlySelectors() {
        let proxy = ZoomNavigationDelegate()
        XCTAssertNil(proxy.downstream)

        // The four directly-implemented methods must be safe with no downstream (no crash).
        proxy.navigationController(nav, willShow: UIViewController(), animated: true)
        proxy.navigationController(nav, didShow: UIViewController(), animated: true)
        let animation = proxy.navigationController(
            nav, animationControllerFor: .push, from: UIViewController(), to: UIViewController()
        )
        let interaction = proxy.navigationController(nav, interactionControllerFor: DummyAnimator())

        XCTAssertNil(animation, "no zoom and no downstream → nil (system default)")
        XCTAssertNil(interaction, "no downstream → nil interaction controller")
        XCTAssertFalse(proxy.responds(to: supportedOrientationsSelector),
                       "with no downstream the proxy must not claim downstream-only capabilities")
    }

    // MARK: - Deallocated downstream

    func test_deallocatedDownstream_respondsFiltersStaleSelector_withoutCrash() {
        let proxy = ZoomNavigationDelegate()

        autoreleasepool {
            let spy = SpyDelegate()
            proxy.downstream = spy
            XCTAssertTrue(proxy.responds(to: supportedOrientationsSelector),
                          "responds must be true while the downstream is alive")
        }

        // `downstream` is weak, so the deallocated spy leaves it nil.
        XCTAssertNil(proxy.downstream, "a deallocated downstream must weakly nil out")
        XCTAssertFalse(proxy.responds(to: supportedOrientationsSelector),
                       "responds(to:) is the stale-call guard: it must report false once the downstream is gone")

        // A caller that honours responds(to:) makes no stale call — no crash.
        if proxy.responds(to: supportedOrientationsSelector) {
            XCTFail("proxy must not claim to respond after the downstream deallocated")
        }
        // NOTE (documented Swift limitation): a belt-and-braces `forwardInvocation:` swallow that
        // would also absorb a stale call from UIKit's *cached* capability flags is not expressible
        // in Swift (NSInvocation is unavailable). The defence is responds(to:) filtering plus
        // delegate re-assignment on `downstream` change — see ZoomNavigationDelegate's type doc.
    }

    // MARK: - Cycle guard

    func test_cycleGuard_selfAsDownstream_isRejected() {
        var messages: [String] = []
        ZoomyAssert.handler = { messages.append($0) }

        let proxy = ZoomNavigationDelegate()
        proxy.downstream = proxy

        XCTAssertEqual(messages.count, 1, "assigning self as downstream must trip the cycle guard")
        XCTAssertNil(proxy.downstream, "a cyclic downstream must be rejected, not stored")
    }

    func test_cycleGuard_indirectChain_isRejected() {
        let a = ZoomNavigationDelegate()
        let b = ZoomNavigationDelegate()
        a.downstream = b // a -> b is fine

        var messages: [String] = []
        ZoomyAssert.handler = { messages.append($0) }

        b.downstream = a // b -> a -> b would cycle

        XCTAssertEqual(messages.count, 1, "a chain that loops back must trip the cycle guard")
        XCTAssertNil(b.downstream, "the cyclic assignment must be rejected")
        XCTAssertTrue(a.downstream === b, "the pre-existing, non-cyclic link must be untouched")
    }

    // MARK: - Own selectors

    func test_respondsToOwnImplementedSelectors_regardlessOfDownstream() {
        let proxy = ZoomNavigationDelegate()
        XCTAssertTrue(proxy.responds(to: #selector(
            ZoomNavigationDelegate.navigationController(_:animationControllerFor:from:to:))))
        XCTAssertTrue(proxy.responds(to: #selector(
            ZoomNavigationDelegate.navigationController(_:willShow:animated:))))
        XCTAssertTrue(proxy.responds(to: #selector(
            ZoomNavigationDelegate.navigationController(_:didShow:animated:))))
        XCTAssertTrue(proxy.responds(to: #selector(
            ZoomNavigationDelegate.navigationController(_:interactionControllerFor:))))
    }
}
