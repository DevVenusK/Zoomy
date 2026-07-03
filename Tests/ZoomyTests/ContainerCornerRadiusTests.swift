import XCTest
import UIKit
@testable import Zoomy

@MainActor
final class ContainerCornerRadiusTests: XCTestCase {

    func test_fullScreenContainer_returnsFullScreenEstimate() {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let containerView = UIView(frame: window.bounds)
        window.addSubview(containerView)

        let radius = ContainerCornerRadius.automaticFinalRadius(for: containerView)

        XCTAssertEqual(radius, ContainerCornerRadius.fullScreenEstimate)
    }

    func test_shrunkContainerWithinAFullScreenWindow_returnsZero() {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let containerView = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.addSubview(containerView)

        let radius = ContainerCornerRadius.automaticFinalRadius(for: containerView)

        XCTAssertEqual(radius, 0)
    }

    func test_nonFullScreenWindow_returnsZeroEvenIfContainerFillsIt() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let containerView = UIView(frame: window.bounds)
        window.addSubview(containerView)

        let radius = ContainerCornerRadius.automaticFinalRadius(for: containerView)

        XCTAssertEqual(radius, 0)
    }

    func test_detachedContainer_returnsZero() {
        let containerView = UIView(frame: UIScreen.main.bounds)

        let radius = ContainerCornerRadius.automaticFinalRadius(for: containerView)

        XCTAssertEqual(radius, 0)
    }
}
