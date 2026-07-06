# SwiftUI Zoom Cover Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let SwiftUI apps on iOS 15+ get Zoomy's app-icon-style zoom into a full-screen hosted SwiftUI destination via two view modifiers (`zoomSource`, `zoomCover`), reusing the existing UIKit modal engine unchanged.

**Architecture:** A thin, purely additive bridge over the modal path. `zoomSource(id:)` plants a transparent marker `UIView` (as a `.background`) into a weak, process-wide registry keyed by id. `zoomCover(item:)` attaches a hidden `UIViewControllerRepresentable` whose `Coordinator` imperatively presents a `UIHostingController` with a `ZoomTransition` whose `sourceViewProvider` looks the marker up by `item.id`. A pure `ZoomCoverReducer` (in `ZoomyCore`, mirroring `TransitionStateMachine`) maps `(desired binding, phase) → action` so the re-entrant SwiftUI update path, rapid re-taps, and the delegate-driven binding write can never loop.

**Tech Stack:** Swift 5.9, SwiftUI + UIKit interop (`UIViewRepresentable`, `UIViewControllerRepresentable`, `UIHostingController`), XCTest. Zero external dependencies.

## Global Constraints

- **iOS 15.0 floor** — every SwiftUI API used must compile and run on iOS 15.0. No `@available` gymnastics needed (the target's floor is already 15).
- **Zero external dependencies** — stdlib/UIKit/SwiftUI/CoreGraphics/os.log only.
- **No `Package.swift` change** — `Zoomy` recursively globs `Sources/Zoomy/**` and already depends on `ZoomyCore`; `ZoomyCore` globs `Sources/ZoomyCore/**`.
- **`ZoomyCore` files import `CoreGraphics`/`Foundation`/stdlib only** — never UIKit/SwiftUI (compiler-enforced boundary).
- **Set `.zoomTransition` BEFORE `present`** — the setter asserts `presentingViewController == nil` (`Sources/Zoomy/UIViewController+ZoomTransition.swift:45`). Order: build host → set transition → present.
- **The `sourceViewProvider` closure must capture ONLY the `id` (value) and `ZoomSourceRegistry.shared` (singleton)** — never the Coordinator or host, or `transition → closure → coordinator → host → (assoc) → transition` forms a retain cycle the `weak delegate` edge does not break.
- **Tests run on the iOS simulator via xcodebuild** (`swift test` fails — the `Zoomy` target imports UIKit). The only eligible simulator on this machine is **iPhone 16 Pro, OS 18.6** (name-only matching fails; the OS is required). Suite command: `xcodebuild test -scheme Zoomy -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6'`. Single class: append `-only-testing:<TestTarget>/<TestClass>`.
- **SwiftUI-importing files guarded with `#if canImport(SwiftUI)`** (hygiene; always true on iOS 15).

---

### Task 1: ZoomCoverReducer (pure decision core)

**Files:**
- Create: `Sources/ZoomyCore/ZoomCoverReducer.swift`
- Test: `Tests/ZoomyCoreTests/ZoomCoverReducerTests.swift`

**Interfaces:**
- Consumes: nothing (pure, stdlib `AnyHashable` only).
- Produces:
  - `enum ZoomCoverPhase: Equatable { case idle, presenting(AnyHashable), presented(AnyHashable), dismissing }`
  - `enum ZoomCoverAction: Equatable { case present(AnyHashable), dismiss, none }`
  - `enum ZoomCoverReducer` with:
    - `static func next(desired: AnyHashable?, phase: ZoomCoverPhase) -> ZoomCoverAction`
    - `static func advanced(_ phase: ZoomCoverPhase) -> ZoomCoverPhase`
    - `static func shouldSyncOnDidEnd(isDismiss: Bool, isCompleted: Bool, isPresentedPhase: Bool) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ZoomyCoreTests/ZoomCoverReducerTests.swift`:

```swift
import XCTest
import ZoomyCore

final class ZoomCoverReducerTests: XCTestCase {

    private let a = AnyHashable("a")
    private let b = AnyHashable("b")

    // MARK: - next(desired:phase:) — exhaustive 8-cell decision table

    func test_next_someIdle_presents() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: a, phase: .idle), .present(a))
    }

    func test_next_noneIdle_none() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: nil, phase: .idle), .none)
    }

    func test_next_somePresenting_defersNone() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: a, phase: .presenting(a)), .none)
    }

    func test_next_nonePresenting_defersNone() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: nil, phase: .presenting(a)), .none)
    }

    func test_next_nonePresented_dismisses() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: nil, phase: .presented(a)), .dismiss)
    }

    func test_next_sameIdPresented_none() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: a, phase: .presented(a)), .none)
    }

    func test_next_differentIdPresented_dismisses() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: b, phase: .presented(a)), .dismiss)
    }

    func test_next_someDismissing_defersNone() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: a, phase: .dismissing), .none)
    }

    func test_next_noneDismissing_defersNone() {
        XCTAssertEqual(ZoomCoverReducer.next(desired: nil, phase: .dismissing), .none)
    }

    // MARK: - advanced(_:) — phase after an animation completes

    func test_advanced_presenting_becomesPresented() {
        XCTAssertEqual(ZoomCoverReducer.advanced(.presenting(a)), .presented(a))
    }

    func test_advanced_dismissing_becomesIdle() {
        XCTAssertEqual(ZoomCoverReducer.advanced(.dismissing), .idle)
    }

    func test_advanced_idleAndPresented_unchanged() {
        XCTAssertEqual(ZoomCoverReducer.advanced(.idle), .idle)
        XCTAssertEqual(ZoomCoverReducer.advanced(.presented(a)), .presented(a))
    }

    // MARK: - shouldSyncOnDidEnd(...) — engine-initiated dismiss detection

    func test_shouldSync_completedDismissWhilePresented_true() {
        XCTAssertTrue(ZoomCoverReducer.shouldSyncOnDidEnd(isDismiss: true, isCompleted: true, isPresentedPhase: true))
    }

    func test_shouldSync_cancelledDismiss_false() {
        XCTAssertFalse(ZoomCoverReducer.shouldSyncOnDidEnd(isDismiss: true, isCompleted: false, isPresentedPhase: true))
    }

    func test_shouldSync_present_false() {
        XCTAssertFalse(ZoomCoverReducer.shouldSyncOnDidEnd(isDismiss: false, isCompleted: true, isPresentedPhase: true))
    }

    func test_shouldSync_notPresentedPhase_false() {
        XCTAssertFalse(ZoomCoverReducer.shouldSyncOnDidEnd(isDismiss: true, isCompleted: true, isPresentedPhase: false))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Zoomy -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -only-testing:ZoomyCoreTests/ZoomCoverReducerTests`
Expected: FAIL — `cannot find 'ZoomCoverReducer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ZoomyCore/ZoomCoverReducer.swift`:

```swift
/// Which SwiftUI zoom-cover presentation state we are in. The `AnyHashable` payload is the id of
/// the item being presented (`Item.id` from `View.zoomCover(item:)`).
public enum ZoomCoverPhase: Equatable {
    case idle
    case presenting(AnyHashable)
    case presented(AnyHashable)
    case dismissing
}

/// The single side effect the SwiftUI coordinator must perform for a given (desired, phase) pair.
public enum ZoomCoverAction: Equatable {
    case present(AnyHashable)
    case dismiss
    case none
}

/// Pure decision core for `View.zoomCover(item:)` — no SwiftUI/UIKit dependency, mirroring
/// `TransitionStateMachine`. `next` maps the desired binding value (`item?.id`) and the current
/// `phase` to exactly one action; `presenting`/`dismissing` are in-flight, so every change during
/// them is deferred (`.none`) and re-evaluated when the coordinator advances the phase on
/// completion. This is what keeps SwiftUI's re-entrant update path, rapid re-taps, and the
/// delegate-driven binding write from looping.
public enum ZoomCoverReducer {

    public static func next(desired: AnyHashable?, phase: ZoomCoverPhase) -> ZoomCoverAction {
        switch (desired, phase) {
        case (.some(let id), .idle):
            return .present(id)
        case (.none, .presented):
            return .dismiss
        case (.some(let id), .presented(let current)):
            return id == current ? .none : .dismiss
        case (_, .presenting), (_, .dismissing):
            return .none
        case (.none, .idle):
            return .none
        }
    }

    /// The phase after a present/dismiss animation completes, before the next `next` runs.
    public static func advanced(_ phase: ZoomCoverPhase) -> ZoomCoverPhase {
        switch phase {
        case .presenting(let id): return .presented(id)
        case .dismissing:         return .idle
        case .idle, .presented:   return phase
        }
    }

    /// Whether an engine-reported `didEnd` should sync the binding back to `nil` — i.e. a completed
    /// dismiss we did not initiate (interactive pan / VoiceOver escape / force-finish). A programmatic
    /// dismiss is in `.dismissing`, so `isPresentedPhase` is `false` and its completion handler owns
    /// the sync instead; a cancelled drag reports `isCompleted == false`.
    public static func shouldSyncOnDidEnd(isDismiss: Bool, isCompleted: Bool, isPresentedPhase: Bool) -> Bool {
        isDismiss && isCompleted && isPresentedPhase
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Zoomy -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -only-testing:ZoomyCoreTests/ZoomCoverReducerTests`
Expected: PASS (all 15 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZoomyCore/ZoomCoverReducer.swift Tests/ZoomyCoreTests/ZoomCoverReducerTests.swift
git commit -m "feat(core): add ZoomCoverReducer pure decision core"
```

---

### Task 2: ZoomSourceRegistry (weak, MainActor)

**Files:**
- Create: `Sources/Zoomy/SwiftUI/ZoomSourceRegistry.swift`
- Test: `Tests/ZoomyTests/ZoomSourceRegistryTests.swift`

**Interfaces:**
- Consumes: `OSLog.zoomy` (internal, defined in `Sources/Zoomy/ZoomTransition.swift:178`).
- Produces (all internal — not consumer API):
  - `@MainActor final class ZoomSourceRegistry` with `static let shared`
  - `func register(_ view: UIView, for id: AnyHashable)`
  - `func deregister(_ view: UIView)`
  - `func view(for id: AnyHashable) -> UIView?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ZoomyTests/ZoomSourceRegistryTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Zoomy -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -only-testing:ZoomyTests/ZoomSourceRegistryTests`
Expected: FAIL — `cannot find 'ZoomSourceRegistry' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Zoomy/SwiftUI/ZoomSourceRegistry.swift`:

```swift
import UIKit
import os.log

/// Process-wide registry mapping a `zoomSource(id:)` id to the live marker `UIView` planted in the
/// SwiftUI hierarchy. `zoomCover`'s `sourceViewProvider` looks the view up by id at animation time.
/// Views are held weakly, so a marker that scrolls out of a lazy container (its representable is
/// dismantled) or is otherwise torn down auto-evicts and the provider cleanly returns `nil` — the
/// engine then falls back to a cross-dissolve. Internal; not consumer API.
@MainActor
final class ZoomSourceRegistry {

    static let shared = ZoomSourceRegistry()

    private final class WeakBox {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var storage: [AnyHashable: WeakBox] = [:]

    /// Registers `view` for `id` (last-writer-wins). A live collision — a *different*, still-alive
    /// view already registered for `id` — is a caller bug (ids must be unique/stable); logged in DEBUG.
    func register(_ view: UIView, for id: AnyHashable) {
        #if DEBUG
        if let existing = storage[id]?.view, existing !== view {
            os_log(
                "Two live zoomSource views share id %{public}@ — ids must be unique",
                log: .zoomy,
                type: .error,
                String(describing: id)
            )
        }
        #endif
        storage[id] = WeakBox(view)
    }

    /// Removes only the entries pointing at `view` (and prunes any dead ones). Identity-guarded so a
    /// stale marker being dismantled after a newer marker claimed the same id can't evict the newer.
    func deregister(_ view: UIView) {
        storage = storage.filter { $0.value.view !== view && $0.value.view != nil }
    }

    /// The live view for `id`, pruning the entry if its weak ref has died.
    func view(for id: AnyHashable) -> UIView? {
        guard let box = storage[id] else { return nil }
        guard let view = box.view else {
            storage[id] = nil
            return nil
        }
        return view
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Zoomy -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -only-testing:ZoomyTests/ZoomSourceRegistryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Zoomy/SwiftUI/ZoomSourceRegistry.swift Tests/ZoomyTests/ZoomSourceRegistryTests.swift
git commit -m "feat(swiftui): add ZoomSourceRegistry (weak, MainActor)"
```

---

### Task 3: zoomSource(id:cornerRadius:) marker

**Files:**
- Create: `Sources/Zoomy/SwiftUI/ZoomSourceModifier.swift`
- Test: `Tests/ZoomyTests/ZoomSourceMarkerViewTests.swift`

**Interfaces:**
- Consumes: `ZoomSourceRegistry.shared` (Task 2).
- Produces:
  - `final class ZoomSourceMarkerView: UIView` (transparent, non-interactive; config in `init`)
  - `struct ZoomSourceMarker: UIViewRepresentable`
  - `public extension View { func zoomSource<ID: Hashable>(id: ID, cornerRadius: CGFloat = 0) -> some View }`

**Note on testing:** `UIViewRepresentable.Context` cannot be constructed in a unit test, so `makeUIView`/`updateUIView`/`dismantleUIView` are verified live by the demo tab (Task 5). What *is* unit-testable — that the marker view is transparent and non-interactive so it never intercepts touches or paints over content — lives in the view's `init` and is covered below.

- [ ] **Step 1: Write the failing test**

Create `Tests/ZoomyTests/ZoomSourceMarkerViewTests.swift`:

```swift
import XCTest
import UIKit
@testable import Zoomy

@MainActor
final class ZoomSourceMarkerViewTests: XCTestCase {

    func test_markerView_isTransparentAndNonInteractive() {
        let view = ZoomSourceMarkerView()
        XCTAssertFalse(view.isUserInteractionEnabled, "marker must never intercept touches")
        XCTAssertEqual(view.backgroundColor, .clear, "marker must be invisible over source content")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Zoomy -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -only-testing:ZoomyTests/ZoomSourceMarkerViewTests`
Expected: FAIL — `cannot find 'ZoomSourceMarkerView' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Zoomy/SwiftUI/ZoomSourceModifier.swift`:

```swift
#if canImport(SwiftUI)
import SwiftUI
import UIKit

/// Transparent, non-interactive marker planted behind a `zoomSource` view. Zoomy's
/// `SourceViewResolver` resolves the on-screen source rect and corner radius from this real
/// `UIView`; its (blank) snapshot placard is an explicitly-tolerated case.
final class ZoomSourceMarkerView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Backs `View.zoomSource(id:cornerRadius:)`. Planted as a `.background`, it matches the source
/// view's frame without affecting layout, and register/deregisters itself across its lifetime.
struct ZoomSourceMarker: UIViewRepresentable {

    let id: AnyHashable
    let cornerRadius: CGFloat

    func makeUIView(context: Context) -> ZoomSourceMarkerView {
        let view = ZoomSourceMarkerView()
        view.layer.cornerRadius = cornerRadius
        ZoomSourceRegistry.shared.register(view, for: id)
        return view
    }

    func updateUIView(_ view: ZoomSourceMarkerView, context: Context) {
        view.layer.cornerRadius = cornerRadius
        // The id bound to this reused view may have changed across a SwiftUI diff: clear any prior
        // mapping for this exact view, then re-register under the current id.
        ZoomSourceRegistry.shared.deregister(view)
        ZoomSourceRegistry.shared.register(view, for: id)
    }

    static func dismantleUIView(_ view: ZoomSourceMarkerView, coordinator: ()) {
        ZoomSourceRegistry.shared.deregister(view)
    }
}

public extension View {

    /// Marks this view as the zoom source registered under `id`. Plants a transparent marker view
    /// (as a `.background`, so no layout impact) that Zoomy resolves the source rect from. `id` must
    /// equal the `Identifiable` id of the item presented via `zoomCover(item:)`; `cornerRadius` is
    /// applied to the marker so `Configuration.cornerMorph == .automatic` reads it.
    func zoomSource<ID: Hashable>(id: ID, cornerRadius: CGFloat = 0) -> some View {
        background(ZoomSourceMarker(id: AnyHashable(id), cornerRadius: cornerRadius))
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Zoomy -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -only-testing:ZoomyTests/ZoomSourceMarkerViewTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Zoomy/SwiftUI/ZoomSourceModifier.swift Tests/ZoomyTests/ZoomSourceMarkerViewTests.swift
git commit -m "feat(swiftui): add zoomSource(id:cornerRadius:) marker"
```

---

### Task 4: zoomCover(item:) with delegate-driven binding sync

**Files:**
- Create: `Sources/Zoomy/SwiftUI/ZoomCoverModifier.swift`
- Test: `Tests/ZoomyTests/ZoomCoverCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ZoomCoverReducer`/`ZoomCoverPhase`/`ZoomCoverAction` (Task 1); `ZoomSourceRegistry.shared` (Task 2); `ZoomTransition`, `ZoomTransition.Configuration`, `ZoomTransition.Context`, `ZoomTransition.Result`, `ZoomTransitionDelegate`, `UIViewController.zoomTransition` (existing engine).
- Produces:
  - `public extension View { func zoomCover<Item: Identifiable, C: View>(item:configuration:content:) -> some View }`
  - `struct ZoomCoverAccessor<Item: Identifiable, C: View>: UIViewControllerRepresentable`
  - `enum ZoomCoverPresenter { static func topmost(from: UIViewController) -> UIViewController }`
  - `@MainActor final class ZoomCoverCoordinator<Item: Identifiable, C: View>: ZoomTransitionDelegate` with internal seams: `var performer`, `func reconcile(desired:)`, `func advance()`, `private(set) var phase`, `var item`, `var content`, `weak var probe`, `func tearDown()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ZoomyTests/ZoomCoverCoordinatorTests.swift`:

```swift
import XCTest
import SwiftUI
import UIKit
@testable import Zoomy
import ZoomyCore

@MainActor
final class ZoomCoverCoordinatorTests: XCTestCase {

    private struct StubItem: Identifiable, Equatable { let id: String }

    private func makeCoordinator(
        recording actions: @escaping (ZoomCoverAction) -> Void
    ) -> ZoomCoverCoordinator<StubItem, Text> {
        let coordinator = ZoomCoverCoordinator<StubItem, Text>(
            configuration: .default,
            content: { Text($0.id) }
        )
        coordinator.performer = actions   // replace the real UIKit performer with a recorder
        return coordinator
    }

    private func didEnd(_ coordinator: ZoomCoverCoordinator<StubItem, Text>, dismiss: Bool, completed: Bool) {
        let context = ZoomTransition.Context(
            zoomedViewController: nil,
            sourceViewController: nil,
            phase: .disappearing,
            operation: dismiss ? .dismiss : .present,
            isInteractive: true
        )
        let result = ZoomTransition.Result(isCompleted: completed, wasInteractive: true, fallbackReason: nil)
        let dummy = ZoomTransition(configuration: .default) { _ in nil }
        coordinator.zoomTransition(dummy, didEnd: context, result: result)
    }

    // MARK: - reconcile → action + phase advancement

    func test_reconcile_fromIdle_recordsPresentAndEntersPresenting() {
        var recorded: [ZoomCoverAction] = []
        let coordinator = makeCoordinator(recording: { recorded.append($0) })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)

        XCTAssertEqual(recorded, [.present(AnyHashable("a"))])
        XCTAssertEqual(coordinator.phase, .presenting(AnyHashable("a")))
    }

    func test_advanceAfterPresent_settlesToPresented_noExtraAction() {
        var recorded: [ZoomCoverAction] = []
        let coordinator = makeCoordinator(recording: { recorded.append($0) })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)   // .presenting(a), records .present
        coordinator.advance()                      // present completed → .presented(a), re-reconcile

        XCTAssertEqual(coordinator.phase, .presented(AnyHashable("a")))
        XCTAssertEqual(recorded, [.present(AnyHashable("a"))], "same item still desired → no dismiss")
    }

    func test_deferredDismiss_appliedOnPresentCompletion() {
        var recorded: [ZoomCoverAction] = []
        let coordinator = makeCoordinator(recording: { recorded.append($0) })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)   // .presenting(a)
        backing = nil                              // user dismisses mid-present-animation
        coordinator.reconcile(desired: backing)   // .presenting → deferred .none
        XCTAssertEqual(recorded, [.present(AnyHashable("a"))])

        coordinator.advance()                      // present completes → .presented → re-reconcile → dismiss
        XCTAssertEqual(recorded, [.present(AnyHashable("a")), .dismiss])
        XCTAssertEqual(coordinator.phase, .dismissing)
    }

    // MARK: - didEnd: engine-initiated dismiss syncs the binding

    func test_didEnd_interactiveCompletedDismiss_whilePresented_clearsBinding() {
        let coordinator = makeCoordinator(recording: { _ in })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)   // .presenting(a)
        coordinator.advance()                      // .presented(a)

        didEnd(coordinator, dismiss: true, completed: true)

        XCTAssertNil(backing, "an engine-initiated dismiss must sync the binding to nil")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_didEnd_cancelledDrag_leavesBindingAndPhase() {
        let coordinator = makeCoordinator(recording: { _ in })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)
        coordinator.advance()                      // .presented(a)

        didEnd(coordinator, dismiss: true, completed: false)   // cancelled drag

        XCTAssertEqual(backing, StubItem(id: "a"))
        XCTAssertEqual(coordinator.phase, .presented(AnyHashable("a")))
    }

    func test_didEnd_present_ignored() {
        let coordinator = makeCoordinator(recording: { _ in })
        var backing: StubItem? = StubItem(id: "a")
        coordinator.item = Binding(get: { backing }, set: { backing = $0 })

        coordinator.reconcile(desired: backing)
        coordinator.advance()                      // .presented(a)

        didEnd(coordinator, dismiss: false, completed: true)   // present didEnd

        XCTAssertEqual(backing, StubItem(id: "a"))
        XCTAssertEqual(coordinator.phase, .presented(AnyHashable("a")))
    }

    // MARK: - topmost presenter walk

    func test_topmost_returnsDeepestNonDismissingPresented() {
        final class Fake: UIViewController {
            var stub: UIViewController?
            override var presentedViewController: UIViewController? { stub }
        }
        let root = Fake(), mid = Fake()
        let leaf = UIViewController()
        root.stub = mid
        mid.stub = leaf
        XCTAssertTrue(ZoomCoverPresenter.topmost(from: root) === leaf)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Zoomy -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -only-testing:ZoomyTests/ZoomCoverCoordinatorTests`
Expected: FAIL — `cannot find 'ZoomCoverCoordinator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Zoomy/SwiftUI/ZoomCoverModifier.swift`:

```swift
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
        // Refresh the closures/binding/configuration to the latest, then reconcile against the
        // desired value. Refreshing `configuration` matters when it derives from view state
        // (e.g. a settings-driven spring) — the next present reads the freshest value.
        context.coordinator.content = content
        context.coordinator.item = item
        context.coordinator.configuration = configuration
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Zoomy -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -only-testing:ZoomyTests/ZoomCoverCoordinatorTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the full suite to confirm nothing regressed**

Run: `xcodebuild test -scheme Zoomy -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6'`
Expected: PASS (all existing + new tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/Zoomy/SwiftUI/ZoomCoverModifier.swift Tests/ZoomyTests/ZoomCoverCoordinatorTests.swift
git commit -m "feat(swiftui): add zoomCover(item:) with delegate-driven binding sync"
```

---

### Task 5: SwiftUI gallery demo tab

**Files:**
- Create: `Example/ZoomyExample/SwiftUIDemo/SwiftUIGalleryView.swift`
- Create: `Example/ZoomyExample/SwiftUIDemo/SwiftUIDetailView.swift`
- Modify: `Example/ZoomyExample/SceneDelegate.swift` (add `import SwiftUI`; append a 5th tab)

**Interfaces:**
- Consumes: `View.zoomSource(id:cornerRadius:)`, `View.zoomCover(item:configuration:content:)` (Tasks 3–4); `DemoSettings.shared.makeConfiguration()` (`Example/ZoomyExample/DemoSettings.swift:47`).
- Produces: `struct SwiftUIGalleryView: View`, `struct SwiftUIDetailView: View`, `struct GalleryItem: Identifiable`.

**Note:** This task is verified by build + manual QA — SwiftUI presentation can't be unit-tested in the SPM bundle (`Tests/ZoomyTests/ZoomTransitionAttachmentTests.swift:200-211`).

- [ ] **Step 1: Create the detail view**

Create `Example/ZoomyExample/SwiftUIDemo/SwiftUIDetailView.swift`:

```swift
import SwiftUI

/// Full-bleed detail shown by the SwiftUI demo's `zoomCover`. Uses an OPAQUE background — a
/// transparent hosted view would let the portal reveal the presenter behind the destination.
struct SwiftUIDetailView: View {

    let item: GalleryItem
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hue: item.hue, saturation: 0.5, brightness: 0.9)
                .ignoresSafeArea()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
        }
    }
}
```

- [ ] **Step 2: Create the gallery view**

Create `Example/ZoomyExample/SwiftUIDemo/SwiftUIGalleryView.swift`:

```swift
import SwiftUI
import Zoomy

/// Grid item with a stable identity; `id` is both the `ForEach` id and the `zoomSource`/`zoomCover` key.
struct GalleryItem: Identifiable, Hashable {
    let id = UUID()
    let hue: Double
}

/// SwiftUI mirror of the UIKit grid tabs: a lazy grid whose tiles are `zoomSource`s, presenting a
/// full-screen `SwiftUIDetailView` via `zoomCover`. Reuses `DemoSettings` so the Settings tab's
/// speed/bounciness sliders drive this transition too.
struct SwiftUIGalleryView: View {

    private let items: [GalleryItem] = (0..<60).map { _ in GalleryItem(hue: .random(in: 0...1)) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    @State private var selected: GalleryItem?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(items) { item in
                    Color(hue: item.hue, saturation: 0.35, brightness: 0.95)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .zoomSource(id: item.id, cornerRadius: 12)
                        .onTapGesture { selected = item }
                }
            }
            .padding(8)
        }
        .navigationTitle("SwiftUI")
        .zoomCover(item: $selected, configuration: DemoSettings.shared.makeConfiguration()) { item in
            SwiftUIDetailView(item: item) { selected = nil }
        }
    }
}
```

- [ ] **Step 3: Wire the tab into SceneDelegate**

In `Example/ZoomyExample/SceneDelegate.swift`, add `import SwiftUI` under `import Zoomy` (line 2), then in `makeRootTabBarController()` add a 5th tab immediately before `let tabBarController = UITabBarController()`:

```swift
        // SwiftUI tab: the same grid + zoom detail built entirely in SwiftUI via the zoomCover bridge.
        let swiftUITab = UINavigationController(
            rootViewController: UIHostingController(rootView: SwiftUIGalleryView())
        )
        swiftUITab.tabBarItem = UITabBarItem(
            title: "SwiftUI",
            image: UIImage(systemName: "swift"),
            tag: 4
        )
```

and append it to the `viewControllers` array (leaving the 0–3 screenshot affordances untouched):

```swift
        tabBarController.viewControllers = [pushTab, modalTab, tortureTab, settingsTab, swiftUITab]
```

- [ ] **Step 4: Regenerate the Xcode project and build**

```bash
cd /Users/finda0603/Desktop/ZoomTransition/Example && xcodegen generate
xcodebuild -project ZoomyExample.xcodeproj -scheme ZoomyExample -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' build
```
Expected: BUILD SUCCEEDED (new files auto-globbed via `sources: - ZoomyExample`).

- [ ] **Step 5: Manual QA (run in the simulator)**

Launch the app, open the **SwiftUI** tab, and confirm:
- Tap a tile → it zooms open into the full-screen detail.
- Pan down on the detail → interactive dismiss; on release the grid returns and the tile is back (binding synced to `nil`).
- Tap the `xmark` → programmatic dismiss zooms back.
- Rapidly tap several tiles → no "present while presenting" console warning.
- Enable **Settings → Accessibility → Reduce Motion** → transition cross-dissolves and still dismisses/syncs.

- [ ] **Step 6: Commit**

```bash
git add Example/ZoomyExample/SwiftUIDemo Example/ZoomyExample/SceneDelegate.swift Example/project.yml
git commit -m "example: add SwiftUI gallery demo tab"
```
(The generated `ZoomyExample.xcodeproj` is gitignored; `project.yml` is only staged if it changed — it should not need edits.)

---

### Task 6: Document the SwiftUI API

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a SwiftUI section**

Add the following section to `README.md` (after the existing UIKit usage, before the `## Example app` section):

````markdown
## SwiftUI

On iOS 15+ you can present a full-screen zoom cover from SwiftUI with two modifiers — no UIKit code:

```swift
struct Photo: Identifiable { let id: UUID; let color: Color }

struct Gallery: View {
    let photos: [Photo]
    @State private var selected: Photo?

    var body: some View {
        LazyVGrid(columns: columns) {
            ForEach(photos) { photo in
                photo.color
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .zoomSource(id: photo.id, cornerRadius: 12)   // mark the source; id must match the item's id
                    .onTapGesture { selected = photo }
            }
        }
        .zoomCover(item: $selected) { photo in                     // present full-screen with the zoom
            PhotoDetail(photo: photo)
        }
    }
}
```

- `zoomSource(id:cornerRadius:)` marks the view a zoom flies out of/into; `id` must equal the presented item's `Identifiable` id, and `cornerRadius` feeds `.automatic` corner morphing.
- `zoomCover(item:configuration:content:)` presents `content(item)` full-screen. Set `item` back to `nil` to dismiss; the interactive pan-to-dismiss and VoiceOver escape sync `item` back to `nil` automatically. Pass a `configuration:` to tune the spring/dimming/etc. exactly as in UIKit.
- Scope: full-screen **cover** only (SwiftUI `NavigationStack` push zoom is not supported). Give the destination an opaque background.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document the SwiftUI zoomCover/zoomSource API"
```

---

## Self-Review Notes

- **Spec coverage:** source registration (Tasks 2–3), presentation + binding sync + no-loop reducer (Tasks 1, 4), demo (Task 5), docs (Task 6). The two correctness landmines from the design — set-before-present and provider-closure capture — are encoded verbatim in Task 4's `presentHost`.
- **Type consistency:** `ZoomCoverPhase`/`ZoomCoverAction`/`ZoomCoverReducer.next/advanced/shouldSyncOnDidEnd` used identically across Tasks 1 and 4; `ZoomSourceRegistry.register/deregister/view(for:)` identical across Tasks 2–4; `GalleryItem` identical across Task 5 files.
- **Deferred/optional:** an `isPresented:sourceID:` bool overload and same-id `rootView` refresh are out of scope for v1 (noted in the design doc).
```
