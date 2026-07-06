import XCTest
import UIKit
@testable import Zoomy

@MainActor
final class ZoomSourceRegistryTests: XCTestCase {

    func test_registerThenLookup_returnsSameView() {
        let registry = ZoomSourceRegistry.shared
        let view = UIView()
        registry.register(view, for: AnyHashable("reg-x"))
        XCTAssertTrue(registry.view(for: AnyHashable("reg-x")) === view)
        registry.deregister(view)
    }

    func test_lastWriterWins_onSameId() {
        let registry = ZoomSourceRegistry.shared
        let first = UIView()
        let second = UIView()
        registry.register(first, for: AnyHashable("reg-y"))
        registry.register(second, for: AnyHashable("reg-y"))
        XCTAssertTrue(registry.view(for: AnyHashable("reg-y")) === second)
        registry.deregister(second)
    }

    func test_deregisterStaleView_doesNotClobberNewerClaim() {
        let registry = ZoomSourceRegistry.shared
        let stale = UIView()
        let fresh = UIView()
        registry.register(stale, for: AnyHashable("reg-z"))
        registry.register(fresh, for: AnyHashable("reg-z"))   // fresh now owns the id
        registry.deregister(stale)                            // stale teardown must not evict fresh
        XCTAssertTrue(registry.view(for: AnyHashable("reg-z")) === fresh)
        registry.deregister(fresh)
    }

    func test_weakEviction_afterViewDeallocs_returnsNil() {
        let registry = ZoomSourceRegistry.shared
        autoreleasepool {
            let view = UIView()
            registry.register(view, for: AnyHashable("reg-w"))
            XCTAssertNotNil(registry.view(for: AnyHashable("reg-w")))
        }
        XCTAssertNil(registry.view(for: AnyHashable("reg-w")))
    }
}
