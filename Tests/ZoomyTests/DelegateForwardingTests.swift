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

    func test_replacingDownstream_routesToNewDownstreamNotOld_whileAttachedToNav() {
        let navController = UINavigationController()
        let proxy = navController.enableZoomTransitions()

        let a = SpyDelegate()
        let b = SpyDelegate()
        proxy.downstream = a
        proxy.downstream = b

        XCTAssertTrue(navController.delegate === proxy,
                      "the proxy must stay installed after the downstream swap (cache re-assignment)")

        _ = (proxy as any UINavigationControllerDelegate).navigationControllerSupportedInterfaceOrientations?(navController)
        proxy.navigationController(navController, willShow: UIViewController(), animated: true)

        XCTAssertEqual(b.supportedOrientationsCount, 1, "the new downstream must receive forwarded calls")
        XCTAssertEqual(b.willShowCount, 1, "the new downstream must receive handed-off calls")
        XCTAssertEqual(a.supportedOrientationsCount, 0, "the replaced downstream must receive nothing")
        XCTAssertEqual(a.willShowCount, 0, "the replaced downstream must receive nothing")
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
