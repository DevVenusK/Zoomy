#if canImport(SwiftUI)
import SwiftUI
import UIKit
import ZoomyCore

public extension View {

    /// Presents `content(item)` full-screen with a Zoomy zoom transition out of the `zoomSource`
    /// whose id equals `item.id`, reusing the modal engine (interactive pan-to-dismiss, corner
    /// morph, and Reduce-Motion fallback included). Setting `item` back to `nil` dismisses; an
    /// interactive or VoiceOver dismiss syncs `item` back to `nil`.
    func zoomCover<Item: Identifiable, C: View>(
        item: Binding<Item?>,
        configuration: ZoomTransition.Configuration = .default,
        @ViewBuilder content: @escaping (Item) -> C
    ) -> some View {
        background(ZoomCoverAccessor(item: item, configuration: configuration, content: content))
    }
}

/// Walks the presented-controller chain to the deepest controller that can present.
enum ZoomCoverPresenter {
    static func topmost(from root: UIViewController) -> UIViewController {
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Hidden host (planted as a `.background`) that captures the presenting `UIViewController` and
/// drives the zoom-cover lifecycle from its `Coordinator`.
struct ZoomCoverAccessor<Item: Identifiable, C: View>: UIViewControllerRepresentable {

    let item: Binding<Item?>
    let configuration: ZoomTransition.Configuration
    let content: (Item) -> C

    func makeCoordinator() -> ZoomCoverCoordinator<Item, C> {
        ZoomCoverCoordinator(configuration: configuration, content: content)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let probe = UIViewController()
        probe.view.backgroundColor = .clear
        probe.view.isUserInteractionEnabled = false
        context.coordinator.probe = probe
        return probe
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Refresh the closures/binding to the latest, then reconcile against the desired value.
        context.coordinator.content = content
        context.coordinator.item = item
        context.coordinator.reconcile(desired: item.wrappedValue)
    }

    static func dismantleUIViewController(
        _ uiViewController: UIViewController,
        coordinator: ZoomCoverCoordinator<Item, C>
    ) {
        coordinator.tearDown()
    }
}

/// Owns all zoom-cover presentation state and doubles as the transition's `ZoomTransitionDelegate`.
/// `reconcile` runs the pure `ZoomCoverReducer` and (for present/dismiss) advances `phase` then hands
/// the action to `performer`; `performer` defaults to the real UIKit present/dismiss but is swapped
/// for a recorder in tests. Every present/dismiss completion calls `advance`, which folds `phase`
/// forward and re-reconciles so a value that changed mid-flight is applied once the engine is idle.
@MainActor
final class ZoomCoverCoordinator<Item: Identifiable, C: View>: NSObject, ZoomTransitionDelegate {

    private(set) var phase: ZoomCoverPhase = .idle
    weak var probe: UIViewController?
    var configuration: ZoomTransition.Configuration
    var content: (Item) -> C
    var item: Binding<Item?> = .constant(nil)

    /// The presented host, retained so we can dismiss it and drop its transition on completion.
    private var host: UIHostingController<C>?

    /// Side-effect performer; swapped for a recorder in tests.
    lazy var performer: (ZoomCoverAction) -> Void = { [weak self] action in
        self?.performUIKit(action)
    }

    init(configuration: ZoomTransition.Configuration, content: @escaping (Item) -> C) {
        self.configuration = configuration
        self.content = content
        super.init()
    }

    /// Runs the reducer for `desired`, moves into the in-flight phase for present/dismiss, and hands
    /// the action to `performer`. `.none` is a no-op (deferred until the next reconcile).
    func reconcile(desired: Item?) {
        let action = ZoomCoverReducer.next(desired: desired.map { AnyHashable($0.id) }, phase: phase)
        switch action {
        case .present(let id):
            phase = .presenting(id)
            performer(.present(id))
        case .dismiss:
            phase = .dismissing
            performer(.dismiss)
        case .none:
            break
        }
    }

    /// Called from a present/dismiss completion: fold `phase` forward, drop the host when idle, and
    /// re-reconcile so a change that arrived mid-flight is applied.
    func advance() {
        let wasDismissing: Bool
        if case .dismissing = phase { wasDismissing = true } else { wasDismissing = false }
        phase = ZoomCoverReducer.advanced(phase)
        if wasDismissing { host = nil }
        reconcile(desired: item.wrappedValue)
    }

    func tearDown() {
        if let host {
            host.dismiss(animated: false)
            self.host = nil
        }
        phase = .idle
    }

    // MARK: - Real UIKit side effects (default performer)

    private func performUIKit(_ action: ZoomCoverAction) {
        switch action {
        case .present(let id): presentHost(id: id)
        case .dismiss:         dismissHost()
        case .none:            break
        }
    }

    private func presentHost(id: AnyHashable) {
        guard let currentItem = item.wrappedValue,
              let root = probe?.view.window?.rootViewController else {
            phase = .idle   // can't present (not yet in a window) — reset so a later update retries
            return
        }
        let presenter = ZoomCoverPresenter.topmost(from: root)

        let host = UIHostingController(rootView: content(currentItem))
        // Capture ONLY `id` (value) + the registry singleton — never self/host — so no retain cycle.
        let transition = ZoomTransition(configuration: configuration) { _ in
            ZoomSourceRegistry.shared.view(for: id)
        }
        transition.delegate = self
        host.zoomTransition = transition          // MUST precede present (setter asserts presentingVC == nil)
        self.host = host

        presenter.present(host, animated: true) { [weak self] in
            self?.advance()
        }
    }

    private func dismissHost() {
        guard let host else { phase = .idle; return }
        host.dismiss(animated: true) { [weak self] in
            self?.advance()
        }
    }

    // MARK: - ZoomTransitionDelegate

    func zoomTransition(
        _ transition: ZoomTransition,
        didEnd context: ZoomTransition.Context,
        result: ZoomTransition.Result
    ) {
        let isPresentedPhase: Bool
        if case .presented = phase { isPresentedPhase = true } else { isPresentedPhase = false }
        guard ZoomCoverReducer.shouldSyncOnDidEnd(
            isDismiss: context.operation == .dismiss,
            isCompleted: result.isCompleted,
            isPresentedPhase: isPresentedPhase
        ) else { return }

        phase = .idle          // set BEFORE the binding write so the resulting update reduces to .none
        host = nil
        if item.wrappedValue != nil {
            item.wrappedValue = nil
        }
        reconcile(desired: item.wrappedValue)
    }
}
#endif
