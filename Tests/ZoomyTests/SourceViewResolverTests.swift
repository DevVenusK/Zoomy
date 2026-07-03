import XCTest
import UIKit
@testable import Zoomy

@MainActor
final class SourceViewResolverTests: XCTestCase {

    private var previousHandler: (@MainActor (String) -> Void)!

    override func setUp() {
        super.setUp()
        previousHandler = ZoomyAssert.handler
    }

    override func tearDown() {
        ZoomyAssert.handler = previousHandler
        super.tearDown()
    }

    private func makeContext() -> ZoomTransition.Context {
        ZoomTransition.Context(
            zoomedViewController: nil,
            sourceViewController: nil,
            phase: .appearing,
            operation: .present,
            isInteractive: false
        )
    }

    private func assertFailure(
        _ result: Result<ResolvedSource, ResolutionFailure>,
        _ expected: ResolutionFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("expected failure \(expected), got success", file: file, line: line)
        case .failure(let failure):
            XCTAssertEqual(failure, expected, file: file, line: line)
        }
    }

    // MARK: - Ladder, in order

    func test_resolve_providerReturnsNil_failsWithProviderNil() {
        let containerView = UIView()
        let zoomedView = UIView()

        let result = SourceViewResolver.resolve(
            provider: { _ in nil },
            context: makeContext(),
            zoomedView: zoomedView,
            containerView: containerView
        )

        assertFailure(result, .providerNil)
    }

    func test_resolve_viewWithNoWindow_failsWithDetached() {
        let containerView = UIView()
        let zoomedView = UIView()
        let sourceView = UIView() // never added to any window

        let result = SourceViewResolver.resolve(
            provider: { _ in sourceView },
            context: makeContext(),
            zoomedView: zoomedView,
            containerView: containerView
        )

        assertFailure(result, .detached)
    }

    func test_resolve_viewInsideZoomedHierarchy_failsAndCallsAssertHandler() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let containerView = UIView(frame: window.bounds)
        let zoomedView = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let sourceView = UIView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))

        window.addSubview(containerView)
        containerView.addSubview(zoomedView)
        zoomedView.addSubview(sourceView) // the destination is its own source — a provider bug

        var handlerCalled = false
        ZoomyAssert.handler = { _ in handlerCalled = true }

        let result = SourceViewResolver.resolve(
            provider: { _ in sourceView },
            context: makeContext(),
            zoomedView: zoomedView,
            containerView: containerView
        )

        assertFailure(result, .insideZoomedHierarchy)
        XCTAssertTrue(handlerCalled)
    }

    func test_resolve_hiddenAncestor_failsWithHiddenAncestor() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let containerView = UIView(frame: window.bounds)
        let zoomedView = UIView() // unrelated to this hierarchy
        let hiddenAncestor = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let sourceView = UIView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))

        window.addSubview(containerView)
        containerView.addSubview(hiddenAncestor)
        hiddenAncestor.addSubview(sourceView)
        hiddenAncestor.alpha = 0

        let result = SourceViewResolver.resolve(
            provider: { _ in sourceView },
            context: makeContext(),
            zoomedView: zoomedView,
            containerView: containerView
        )

        assertFailure(result, .hiddenAncestor)
    }

    func test_resolve_hiddenViaIsHiddenFlag_failsWithHiddenAncestor() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let containerView = UIView(frame: window.bounds)
        let zoomedView = UIView()
        let sourceView = UIView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        sourceView.isHidden = true

        window.addSubview(containerView)
        containerView.addSubview(sourceView)

        let result = SourceViewResolver.resolve(
            provider: { _ in sourceView },
            context: makeContext(),
            zoomedView: zoomedView,
            containerView: containerView
        )

        assertFailure(result, .hiddenAncestor)
    }

    func test_resolve_scrollClippedBelowThreshold_failsWithInsufficientVisibilityRatio() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false // a freshly-init UIWindow defaults to hidden, which would
        // otherwise trip the resolver's own ancestor-hidden check (step 4) before ever reaching
        // the visibility-ratio check this test targets.
        let containerView = UIView(frame: window.bounds)
        let zoomedView = UIView()
        let scrollView = UIScrollView(frame: CGRect(x: 50, y: 50, width: 100, height: 100))
        // 70pt of this 100pt-wide cell sits outside the scroll view's 100pt-wide bounds, i.e.
        // only 30% (ratio 0.3) is visible — below the 0.35 threshold.
        let sourceView = UIView(frame: CGRect(x: 70, y: 0, width: 100, height: 100))

        window.addSubview(containerView)
        containerView.addSubview(scrollView)
        scrollView.addSubview(sourceView)
        scrollView.contentSize = CGSize(width: 170, height: 100)

        let result = SourceViewResolver.resolve(
            provider: { _ in sourceView },
            context: makeContext(),
            zoomedView: zoomedView,
            containerView: containerView
        )

        switch result {
        case .success:
            XCTFail("expected insufficientVisibility, got success")
        case .failure(let failure):
            guard case .insufficientVisibility(let ratio) = failure else {
                XCTFail("expected insufficientVisibility, got \(failure)")
                return
            }
            XCTAssertEqual(ratio, 0.3, accuracy: 0.01)
        }
    }

    func test_resolve_offscreenView_failsWithOffContainer() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        let containerView = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let zoomedView = UIView()
        let sourceView = UIView(frame: CGRect(x: 1_000, y: 1_000, width: 50, height: 50))

        window.addSubview(containerView)
        window.addSubview(sourceView) // sibling of containerView, far outside its bounds

        let result = SourceViewResolver.resolve(
            provider: { _ in sourceView },
            context: makeContext(),
            zoomedView: zoomedView,
            containerView: containerView
        )

        assertFailure(result, .offContainer)
    }

    // MARK: - Success path: precise coordinate conversion

    func test_resolve_success_computesRectVisibleRectAndCornerRadiusPrecisely() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        let containerView = UIView(frame: window.bounds)
        let zoomedView = UIView()
        let sourceView = UIView(frame: CGRect(x: 40, y: 60, width: 100, height: 50))
        sourceView.layer.cornerRadius = 12

        window.addSubview(containerView)
        containerView.addSubview(sourceView)

        let result = SourceViewResolver.resolve(
            provider: { _ in sourceView },
            context: makeContext(),
            zoomedView: zoomedView,
            containerView: containerView
        )

        switch result {
        case .failure(let failure):
            XCTFail("expected success, got \(failure)")
        case .success(let resolved):
            XCTAssertTrue(resolved.view === sourceView)
            XCTAssertEqual(resolved.rectInContainer, CGRect(x: 40, y: 60, width: 100, height: 50))
            XCTAssertEqual(resolved.visibleRectInContainer, resolved.rectInContainer)
            XCTAssertEqual(resolved.cornerRadius, 12, accuracy: 0.001)
            // Snapshotting is environment-dependent in a headless test run — either a real
            // placard or nil is an acceptable success per the brief (nil must not fail
            // resolution). We only assert we can touch it without crashing.
            _ = resolved.placard
        }
    }

    func test_resolve_success_partiallyClippedButAboveThreshold_reportsReducedVisibleRect() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        let containerView = UIView(frame: window.bounds)
        let zoomedView = UIView()
        let clippingAncestor = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        clippingAncestor.clipsToBounds = true
        // 60% of this 100pt-wide view's width is inside the clipping ancestor (ratio 0.6),
        // comfortably above the 0.35 threshold.
        let sourceView = UIView(frame: CGRect(x: 40, y: 20, width: 100, height: 40))

        window.addSubview(containerView)
        containerView.addSubview(clippingAncestor)
        clippingAncestor.addSubview(sourceView)

        let result = SourceViewResolver.resolve(
            provider: { _ in sourceView },
            context: makeContext(),
            zoomedView: zoomedView,
            containerView: containerView
        )

        switch result {
        case .failure(let failure):
            XCTFail("expected success, got \(failure)")
        case .success(let resolved):
            XCTAssertEqual(resolved.rectInContainer, CGRect(x: 40, y: 20, width: 100, height: 40))
            XCTAssertEqual(resolved.visibleRectInContainer, CGRect(x: 40, y: 20, width: 60, height: 40))
        }
    }
}
