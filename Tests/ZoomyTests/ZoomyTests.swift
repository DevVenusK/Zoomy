import XCTest
@testable import Zoomy

final class ZoomyTests: XCTestCase {
    func testModuleImports() {
        // Trivial sanity check that the Zoomy module builds and links correctly.
        XCTAssertNotNil(Zoomy.self)
    }
}
