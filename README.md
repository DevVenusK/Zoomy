# Zoomy

![Platform](https://img.shields.io/badge/platform-iOS%2015%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.9%2B-orange)
![UIKit](https://img.shields.io/badge/UIKit-000000)
![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

Zoomy generalizes iOS's home-screen "app opens by zooming from its icon" transition to plain
UIKit: `UINavigationController` push/pop and modal present/dismiss both get a zoom that expands
from — and shrinks back to — any view you point it at, with an interactive finger-follow
dismiss/pop built in.

- **iOS 15+**, Swift 5.9+, UIKit only
- **Zero dependencies**
- Small public surface (`ZoomTransition` + two extension entry points), everything else internal

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Behavior](#behavior)
- [Caveats](#caveats)
- [Example app](#example-app)
- [License](#license)

## Installation

### Swift Package Manager

Add Zoomy as a dependency in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<your-org>/Zoomy.git", branch: "main")
],
targets: [
    .target(name: "YourApp", dependencies: ["Zoomy"])
]
```

(No tagged release exists yet — pin to a version once one is cut.)

Or, in Xcode: **File → Add Package Dependencies…**, paste the repository URL, and add the
`Zoomy` library to your app target.

## Quick start

### Modal present/dismiss

Attach a `ZoomTransition` to the view controller you're about to present, then present it as
usual — Zoomy takes care of the presentation style and transitioning delegate for you.

```swift
import Zoomy

let detail = PhotoDetailViewController(photo: photo)

// ⚠️ Capture a stable identifier (`photo.id`), not an `IndexPath`. The provider closure runs
// again at the start of every animation phase (present, dismiss, and settle), so if you capture
// an index path directly it will silently point at the wrong cell — or a cell that no longer
// exists — the moment the data source reloads or the item moves. Re-resolve the index path from
// the stable ID every time instead.
let photoID = photo.id
detail.zoomTransition = ZoomTransition { [weak self] _ in
    guard let self, let index = self.photos.firstIndex(where: { $0.id == photoID }) else {
        return nil // Zoomy falls back to a cross-dissolve instead of crashing.
    }
    let indexPath = IndexPath(item: index, section: 0)
    return (self.collectionView.cellForItem(at: indexPath) as? PhotoCell)?.photoView
}

present(detail, animated: true)
```

### Push/pop

Install the navigation proxy once per `UINavigationController`, then attach a `zoomTransition`
to any view controller you push — the adjacent pop back to its predecessor zooms too.

```swift
import Zoomy

// Once, e.g. right after creating the navigation controller:
navigationController.enableZoomTransitions()

// Per destination, same source-view-provider pattern as modal:
let detail = PhotoDetailViewController(photo: photo)
let photoID = photo.id
detail.zoomTransition = ZoomTransition { [weak self] _ in
    guard let self, let index = self.photos.firstIndex(where: { $0.id == photoID }) else {
        return nil
    }
    let indexPath = IndexPath(item: index, section: 0)
    return (self.collectionView.cellForItem(at: indexPath) as? PhotoCell)?.photoView
}

navigationController.pushViewController(detail, animated: true)
```

### Apps that already own `UINavigationControllerDelegate` (Coordinator / RxCocoa)

`enableZoomTransitions()` installs its own delegate proxy and wraps whatever was there before —
convenient, but it doesn't compose with libraries that install *their own* delegate proxy on the
same navigation controller (RxCocoa's `rx.delegate`, most Coordinator patterns). Don't call
`enableZoomTransitions()` there — own `ZoomNavigationDelegate` explicitly instead:

```swift
import Zoomy

// Hold `zoomDelegate` as a property — `UINavigationController.delegate` is weak.
let zoomDelegate = ZoomNavigationDelegate(forwardingTo: myExistingDelegate)
navigationController.delegate = zoomDelegate

// If you later swap or drop `myExistingDelegate`, reassign it *through* `zoomDelegate` (not by
// touching `navigationController.delegate` directly) so UIKit's cached delegate-capability flags
// get invalidated:
zoomDelegate.downstream = myNewDelegate
```

## Configuration

`ZoomTransition.Configuration` is passed once, at `init`, and is immutable for the transition's
lifetime:

```swift
var configuration = ZoomTransition.Configuration.default
configuration.dimmingColor = nil
configuration.cornerMorph = .fixed(from: 12, to: 0)
let transition = ZoomTransition(configuration: configuration) { _ in sourceView }
```

| Property | Type | Default | Description |
|---|---|---|---|
| `spring` | `ZoomTransition.Spring` | `.init(response: 0.44, dampingRatio: 0.85)` | Spring driving the zoom-in/zoom-out and settle animations. |
| `dimmingColor` | `UIColor?` | `.black.withAlphaComponent(0.3)` | Backdrop shown behind a modal zoom. `nil` disables dimming entirely. |
| `cornerMorph` | `.automatic` \| `.fixed(from:to:)` \| `.none` | `.automatic` | How the corner radius morphs across the transition. `.automatic` derives it from the source view and the container; `.fixed` pins explicit start/end radii; `.none` disables morphing. |
| `interactiveDismissal` | `.pan` \| `.disabled` | `.pan` | `.pan` installs the finger-follow interactive dismiss/pop (and, on a navigation controller, the edge-swipe pop); `.disabled` turns it off (tap/back-button only). |
| `fallback` | `.crossDissolve` \| `.systemDefault` | `.crossDissolve` | Animation used whenever the zoom can't run (unresolved source, Reduce Motion, VoiceOver, ...). `.systemDefault` defers to UIKit's stock transition instead. |
| `respectsReduceMotion` | `Bool` | `true` | When `true`, Reduce Motion / Prefer Cross-Fade Transitions short-circuits to `fallback` instead of running the zoom. |
| `resignsFirstResponders` | `Bool` | `true` | When `true`, Zoomy calls `endEditing(true)` on present and at the start of an interactive dismiss/pop, so an open keyboard doesn't fight the transition. |

`ZoomTransition.dismissalPanGesture` exposes the installed interactive-dismiss `UIPanGestureRecognizer`
(non-`nil` once installed, `nil` while `interactiveDismissal == .disabled`) so you can arbitrate it
against your own recognizers — e.g. `scrollView.panGestureRecognizer.require(toFail:)`.

## Behavior

- **Interactive dismiss/pop** — drag to shrink the destination back toward its source; release to
  either spring the rest of the way closed or snap back. Scrubbing, cancelling mid-drag, and
  re-grabbing mid-settle are all supported.
- **Edge-swipe pop** — on a navigation controller with `enableZoomTransitions()` installed, the
  system left-edge back-swipe drives the same interactive zoom pop on a zoom screen; every other
  screen keeps the stock system pop, byte-for-byte.
- **Source re-resolution** — the source-view provider is called again at the start of every
  animation phase, so cell reuse and scrolling between present/push and dismiss/pop are handled
  automatically. When the source can't be found or resolves to something that's not usably
  visible, Zoomy falls back to `configuration.fallback` instead of animating from a stale rect.
- **Accessibility** — Reduce Motion / Prefer Cross-Fade Transitions and VoiceOver both
  automatically switch to a non-zoom cross-dissolve; VoiceOver additionally suppresses interactive
  dismissal so a swipe doesn't fight VoiceOver's own gestures.
- **Rotation / backgrounding** — a rotation, size-class change, or the owning scene entering the
  background fast-forwards any in-flight transition to a clean finished/cancelled state instead of
  leaving it stuck mid-animation.

## Caveats

Real sharp edges, found the hard way. Read these before shipping a zoom transition.

1. **`.custom` presentation never calls the presenter's `viewWillAppear`/`viewWillDisappear`.**
   Zoomy's modal path always presents with `.custom` (that's how it keeps the presenter's view in
   the hierarchy for the zoom). If a screen you're zooming *from* refreshes data or does analytics
   in those lifecycle callbacks, that logic will silently stop firing across the transition —
   check for this if you're moving a screen from `.fullScreen` presentation to a Zoomy modal zoom.

2. **Don't combine `enableZoomTransitions()` with another delegate-proxy library on the same
   navigation controller** (RxCocoa's `rx.delegate`, most Coordinator setups). Both install their
   own `UINavigationControllerDelegate` proxy and they will fight over `navigationController.delegate`.
   Own an explicit `ZoomNavigationDelegate(forwardingTo:)` yourself instead (see
   [Quick start](#apps-that-already-own-uinavigationcontrollerdelegate-coordinator--rxcocoa)),
   and reassign `downstream` (not `navigationController.delegate` directly) whenever the wrapped
   delegate changes.

3. **Push-zoom status bar style isn't inherited from the pushed view controller** — this is a
   plain UIKit constraint: a `UINavigationController` doesn't delegate `preferredStatusBarStyle`
   to its top view controller by default. If a full-screen pushed detail needs its own status bar
   style, subclass `UINavigationController` and override `childForStatusBarStyle` to return
   `topViewController`. (The bundled Example only demonstrates the modal case, via
   `modalPresentationCapturesStatusBarAppearance`; it does not yet include a push-side
   `childForStatusBarStyle` subclass.)

4. **Capture `[weak self]` (or whatever owns the source view) in the source-view provider.** The
   destination view controller retains its `ZoomTransition`, which retains the provider closure —
   a strong capture there can keep the source side alive longer than you expect, or form a cycle
   if the source ever references the destination back.

5. **The provider re-resolves cell *identity*, not data *identity*.** Calling the provider again
   on every animation phase correctly finds "the cell that currently represents this stable ID,"
   but it does nothing for you if the underlying item was deleted or moved — that mapping (stable
   ID → current index path) is on you, as in the Quick start examples above.

6. **Hide the destination's navigation bar.** Showing the navigation bar on both sides of a push
   zoom (especially combined with a large title) makes UIKit's mid-flight bar cross-fade unreliable
   during an interactive grab/cancel (a long-standing iOS ghosting issue). The Example hides the
   bar on its pushed detail screen (`setNavigationBarHidden(true)`) for this reason — do the same
   unless you've specifically verified your bar configuration survives a cancelled interactive pop.

7. **Not supported**: `.pageSheet`/`.formSheet`/`.popover` presentation for a Zoomy-driven
   destination — assigning `zoomTransition` always forces `.custom` presentation, so it can't be
   combined with a sheet or popover style. tvOS and Mac Catalyst are untested and outside CI;
   `Package.swift` only declares `.iOS(.v15)` as a supported platform.

## Example app

```sh
cd Example
xcodegen generate
open ZoomyExample.xcodeproj
```

(Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen); `brew install xcodegen`. You can
also build/run from the command line with `xcodebuild -project ZoomyExample.xcodeproj -scheme
ZoomyExample -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`.)

Three tabs:

- **Push** — a photo grid pushing a full-screen detail with a push zoom.
- **Modal** — the same grid, presenting the detail with a modal zoom.
- **Torture** — a manual-QA harness for edge cases that don't lend themselves to unit tests: a
  source scrolled off-screen, a reload that invalidates the source (fallback), presenting with the
  keyboard up, a `hidesBottomBarWhenPushed` push, and a half-clipped source tile.

## License

MIT — see [LICENSE](LICENSE).
