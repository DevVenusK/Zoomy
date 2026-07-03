# Zoomy — 구현 테크스펙 (v1.0)

> 기반 문서: `docs/2026-07-03-design.md` (적대적 리뷰 반영 v2)
> 이 문서는 설계 문서를 **파일 단위로 구현 가능한 수준**까지 구체화한다. 설계와 어긋나는 정제 사항은 §14에 명시.

---

## 1. 목적 / 비목적

**목적**: iOS 홈 화면 앱-열기 zoom transition을 UIKit push/pop·present/dismiss에 일반화. iOS 15+, 의존성 0, SPM.

**비목적 (v1)**: 스크롤뷰 pull-to-dismiss 연동 · non-UIView 소스 · 다중 뷰 매칭 · SwiftUI 브리지 · iOS 18 네이티브 `.zoom` 위임 · sheet/popover 스타일 · tvOS/Catalyst · Strategy 프로토콜 공개.

---

## 2. 배포 타깃

```swift
// Package.swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Zoomy",
    platforms: [.iOS(.v15)],
    products: [.library(name: "Zoomy", targets: ["Zoomy"])],
    targets: [
        .target(name: "Zoomy"),
        .testTarget(name: "ZoomyTests", dependencies: ["Zoomy"])
    ]
)
```

- 저장소 폴더명 `ZoomTransition`, 모듈명 `Zoomy` (핵심 타입 `ZoomTransition`과의 모듈==타입명 충돌 회피).
- 전 타입 `@MainActor` 또는 main-thread assert. Swift 6 strict concurrency는 v1 비목표(경고 0 유지만).
- Example 앱은 별도 xcodeproj(`Example/ZoomyExample`)로 로컬 패키지 참조.

---

## 3. Public API 명세 (전체 — 이것이 v1 공개 표면의 전부)

### 3.1 ZoomTransition

```swift
// Sources/Zoomy/ZoomTransition.swift
@MainActor
public final class ZoomTransition: NSObject {

    /// 모든 애니메이션 단계(present, dismiss 시작, settle) 시작 시 메인 스레드에서 재호출된다.
    /// 계약: 순수할 것(레이아웃 변형·내비게이션 호출 금지), 반환 뷰는 non-transitioning 쪽
    /// 계층 소속일 것(목적지 자신의 서브뷰 금지), nil 반환 시 configuration.fallback 적용.
    public typealias SourceViewProvider = (Context) -> UIView?

    public let configuration: Configuration          // 불변
    public weak var delegate: ZoomTransitionDelegate?

    /// 인터랙티브 dismiss가 설치된 후 non-nil. 스크롤뷰 등과의 제스처 중재
    /// (`require(toFail:)`)를 소비자가 배선하는 유일한 통로.
    public var dismissalPanGesture: UIPanGestureRecognizer? { get }

    public init(configuration: Configuration = .default,
                sourceViewProvider: @escaping SourceViewProvider)
}

extension ZoomTransition {
    public enum Phase: Sendable { case appearing, disappearing }
    public enum Operation: Sendable { case push, pop, present, dismiss }

    public struct Context {
        public weak var zoomedViewController: UIViewController?
        public weak var sourceViewController: UIViewController?
        public let phase: Phase
        public let operation: Operation
        public let isInteractive: Bool
    }

    /// didEnd에서 정확히 1회 전달. fallbackReason != nil 이면 zoom 대신 대체 애니메이션이 실행된 것.
    public struct Result: Equatable, Sendable {
        public let isCompleted: Bool        // false == cancelled
        public let wasInteractive: Bool
        public let fallbackReason: FallbackReason?
    }

    public enum FallbackReason: Equatable, Sendable {
        case sourceUnresolved      // provider nil 또는 검증 사다리 실패
        case notWired              // zoomTransition은 있으나 delegate 체인 미도달 (진단용)
        case reentrant             // state != .idle 에서 begin
        case reduceMotion          // Reduce Motion / VoiceOver 단락
        case unsupportedOperation  // 다단 pop, setViewControllers 등
    }
}
```

### 3.2 Configuration

```swift
extension ZoomTransition {
    public struct Configuration {
        public static let `default` = Configuration()

        public var spring: Spring = .init(response: 0.44, dampingRatio: 0.85)
        public var dimmingColor: UIColor? = UIColor.black.withAlphaComponent(0.3) // nil = 디밍 없음
        public var cornerMorph: CornerMorph = .automatic
        public var interactiveDismissal: InteractiveDismissal = .pan
        public var fallback: Fallback = .crossDissolve
        public var respectsReduceMotion: Bool = true
        public var resignsFirstResponders: Bool = true
        public init() {}

        public enum CornerMorph: Equatable {
            case automatic                       // 소스 layer.cornerRadius → 컨테이너 문맥 radius(§6.5)
            case fixed(from: CGFloat, to: CGFloat)
            case none
        }
        public enum InteractiveDismissal: Equatable { case pan, disabled }
        public enum Fallback: Equatable { case crossDissolve, systemDefault }
    }

    public struct Spring: Hashable, Sendable {
        public var response: TimeInterval    // ≈ 지각 duration
        public var dampingRatio: CGFloat
        public init(response: TimeInterval, dampingRatio: CGFloat)
    }
}
```

### 3.3 Delegate

```swift
// Sources/Zoomy/ZoomTransitionDelegate.swift
@MainActor
public protocol ZoomTransitionDelegate: AnyObject {
    func zoomTransition(_ transition: ZoomTransition, willBegin context: ZoomTransition.Context)
    func zoomTransition(_ transition: ZoomTransition, didEnd context: ZoomTransition.Context,
                        result: ZoomTransition.Result)
}
public extension ZoomTransitionDelegate {  // 전부 기본 no-op
    func zoomTransition(_: ZoomTransition, willBegin _: ZoomTransition.Context) {}
    func zoomTransition(_: ZoomTransition, didEnd _: ZoomTransition.Context,
                        result _: ZoomTransition.Result) {}
}
```

호출 규칙: `willBegin`은 소스 해석 **직전**(앱이 `scrollToItem(animated: false)` + `layoutIfNeeded()`로 복원할 기회), `didEnd`는 cleanup 완료 직후 정확히 1회.

### 3.4 UIViewController 확장

```swift
// Sources/Zoomy/UIViewController+ZoomTransition.swift
extension UIViewController {
    public var zoomTransition: ZoomTransition? { get set }
}
```

**setter 의미론 (정확히 이 순서):**
1. `precondition(presentingViewController == nil)` — present 이후 할당 금지.
2. 새 값이 이미 다른 VC에 부착돼 있으면 `assertionFailure("ZoomTransition은 VC당 1개")` (release는 no-op 거부).
3. **스냅샷**: 최초 할당 시 현재 `(modalPresentationStyle, transitioningDelegate)`를 associated object로 저장.
4. 설치: `modalPresentationStyle = .custom`, `transitioningDelegate = transition.modalAdapter`.
   (완전 lazy 설치는 스위즐링 없이는 불가 — UIKit이 `present` 시점에 delegate를 읽으므로 setter에서 설치하되, **소비자가 이후 style을 직접 바꾸면 그 값을 존중**한다. dismiss 경로는 `.custom`/`.fullScreen`/`.overFullScreen` 3분기 지원, §7.2.)
5. `objc_setAssociatedObject(self, &key, transition, .retain)` — `transitioningDelegate`가 weak이므로 여기서 수명 보장. transition에 `weak attachedViewController = self` 기록.
6. `nil` 할당: 우리 delegate일 때만 해제하고 **스냅샷 원값 복원**(임의 상수 `.fullScreen` 복원 금지), associated object 제거.

push 경로에서는 이 setter의 modal 설치가 무해하게 방치된다(문서화). pop 인접성 판정을 위해 push animator vend 시점에 `transition.pushPredecessor = fromVC` (weak) 기록.

### 3.5 Navigation API

```swift
// Sources/Zoomy/Navigation/UINavigationController+Zoomy.swift
extension UINavigationController {
    /// 현재 delegate를 downstream으로 감싸는 ZoomNavigationDelegate를 설치하고 반환.
    /// 이미 우리 프록시면 그것을 반환(멱등). RxCocoa 등 delegate-proxy 라이브러리와 병용 금지(README).
    @discardableResult
    public func enableZoomTransitions() -> ZoomNavigationDelegate
}

// Sources/Zoomy/Navigation/ZoomNavigationDelegate.swift
@MainActor
public final class ZoomNavigationDelegate: NSObject, UINavigationControllerDelegate {
    public init(forwardingTo downstream: UINavigationControllerDelegate? = nil)
    /// didSet: 부착된 nav가 있으면 nav.delegate = nil; nav.delegate = self 재할당
    /// → UIKit delegate capability-flag 캐시 무효화.
    public weak var downstream: UINavigationControllerDelegate? { get set }
}
```

**프록시 포워딩 규칙 (구현 명세):**

| 셀렉터 | 처리 |
|---|---|
| `navigationController(_:animationControllerFor:from:to:)` | 직접 구현 — vend 규칙 §7.3 |
| `navigationController(_:interactionControllerFor:)` | 직접 구현 — 직전에 vend한 zoom driver 반환, 아니면 downstream |
| `willShow` / `didShow` | 직접 구현: 내부 훅(edge-swipe 설치, pushPredecessor 정리) 수행 **후** downstream에 수동 전달 |
| 그 외 전부 | `responds(to:)` = self ∥ downstream, `forwardingTarget(for:)` = downstream |
| downstream 소멸 후 stale 호출 | `methodSignature(for:)`가 downstream 부재 시 캐시된/합성 시그니처 반환 + `forwardInvocation:` no-op (zero 반환) — `doesNotRecognizeSelector` 크래시 방지 |

설치 시 순환 가드: downstream 체인을 따라가며 `=== self` 발견 시 `assertionFailure`. 프록시는 nav의 associated object로 retain, `nav`는 weak 보관.

---

## 4. 소유/참조 그래프

```
UIViewController(destination)
  ── assoc(.retain) ──▶ ZoomTransition
        │ strong: configuration, modalAdapter, interactionDriver(생성 후)
        │ weak:   delegate, attachedViewController, pushPredecessor
        └ strong(전환 중에만): activeTransition: ActiveTransition?

ActiveTransition (struct, 전환별 강참조의 유일한 컨테이너)
  context(UIViewControllerContextTransitioning), geometry, portal,
  transitionAnimator, geometryAnimators[], restorationToken, resolvedSource,
  pendingAnimatorCount, didCleanUp, contextInfo(Context)

UINavigationController ── assoc(.retain) ──▶ ZoomNavigationDelegate
                                                weak: nav, downstream

RestorationToken: 복원 클로저 배열(뷰는 weak 캡처) — deinit == restore() 백스톱
```

- `activeTransition = nil`은 **cleanup에서만** 수행. 애니메이터 블록이 뷰를 캡처하므로 이것이 해제 지점.
- `deinit`(ZoomTransition): 살아있는 animator가 있으면 `stopAnimation(false)` + 상태 가드 후 `finishAnimation(at: .current)` (active 상태 animator dealloc 크래시 방지).

---

## 5. 내부 타입 명세

### 5.1 TransitionStateMachine (pure Swift, UIKit import 금지)

```swift
enum Direction: Equatable { case zoomIn, zoomOut }

enum TransitionState: Equatable {
    case idle
    case animating(Direction)
    case interactive(Direction)
    case settling(Direction, toCompleted: Bool)
}

enum TransitionEvent: Equatable {
    case begin(Direction, interactive: Bool)
    case grab                     // 손가락이 비행 중 전환을 잡음
    case update(CGFloat)          // radial progress 0...1
    case release(toCompleted: Bool)
    case allAnimatorsFinished
    case forceFinish(ForceReason) // sizeChange / sceneBackground / abandoned
}

enum SideEffect: Equatable {
    case startAnimators                    // 비인터랙티브 개시
    case startPausedForGesture             // 제스처 개시: transitionAnimator paused 생성
    case freezeGeometryAndPauseTransition  // grab: geometry kill+stamp, transition pause(정방향) 또는 rebuild(역방향)
    case applyFollow(CGFloat)              // portal에 직접 기하 적용 + fraction 스크럽 + updateInteractiveTransition
    case settle(toCompleted: Bool)         // finish/cancelInteractiveTransition → 스프링 발사 → continue/reverse
    case fastForwardAll(toCompleted: Bool)
    case cleanupAndComplete(completed: Bool)
    case rejectBegin                       // .fellBack(.reentrant) 보고
}

struct TransitionStateMachine {
    private(set) var state: TransitionState = .idle
    @discardableResult
    mutating func handle(_ event: TransitionEvent) -> [SideEffect]
}
```

**전이 테이블 (전수 — 표에 없는 조합은 debug assert + `[]`):**

| 현재 상태 | 이벤트 | 다음 상태 | 사이드이펙트 |
|---|---|---|---|
| idle | begin(d, false) | animating(d) | [startAnimators] |
| idle | begin(d, true) | interactive(d) | [startPausedForGesture] |
| animating(d) | grab | interactive(d) | [freezeGeometryAndPauseTransition] |
| animating(d) | allAnimatorsFinished | idle | [cleanupAndComplete(true)] |
| interactive(d) | update(p) | interactive(d) | [applyFollow(p)] |
| interactive(d) | release(c) | settling(d, c) | [settle(c)] |
| settling(d, c) | grab | interactive(d) | [freezeGeometryAndPauseTransition] |
| settling(d, c) | allAnimatorsFinished | idle | [cleanupAndComplete(c)] |
| animating/interactive/settling | forceFinish(r) | idle | [fastForwardAll(toCompleted: §7.6 방향 규칙), cleanupAndComplete(...)] |
| ≠idle | begin | (불변) | [rejectBegin] |
| idle | 그 외 | idle | [] (no-op — 지연 도착 이벤트 허용) |

퍼지 테스트 불변식: 어떤 이벤트 시퀀스에서도 `cleanupAndComplete`는 begin당 최대 1회.

### 5.2 ZoomGeometry + FollowModel (pure Swift)

```swift
struct ZoomGeometry: Equatable {
    let sourceRect: CGRect            // 컨테이너 좌표
    let sourceVisibleRect: CGRect     // 클리핑 조상 반영 (§7.5)
    let finalRect: CGRect             // transitionContext.finalFrame(for:)
    let sourceCornerRadius: CGFloat
    let finalCornerRadius: CGFloat

    func portalRect(at progress: CGFloat) -> CGRect        // lerp, progress 언클램프(스프링 오버슈트)
    func cornerRadius(at progress: CGFloat) -> CGFloat     // lerp 후 min(bounds)/2 클램프
    func contentScale(portalWidth: CGFloat) -> CGFloat     // portalWidth / finalRect.width
    // 콘텐츠 transform: 최종 크기로 레이아웃된 라이브 뷰를 top-center 앵커로 widthScale 축소
    static func rubberBand(_ x: CGFloat, dimension: CGFloat, c: CGFloat = 0.55) -> CGFloat
    // = sign(x) · (1 − 1/(|x|·c/d + 1)) · d
}

struct FollowModel {
    let containerSize: CGSize          // H = containerSize.height
    let initialCenter: CGPoint         // grab/제스처 시작 시 portal presentation center

    // 상수(튜닝 파라미터, 전부 이 타입 안에 상수로 고정):
    // kX = 0.5, span = 0.55·H, scaleRange = 0.45, scaleFloor = 0.55, rampEnd = 0.2
    func progress(for t: CGPoint) -> CGFloat
    // = clamp((max(t.y, 0) + kX·|t.x|) / span, 0, 1)   ← radial: 가로 이동도 진행에 기여
    func scale(forProgress p: CGFloat) -> CGFloat
    // = max(scaleFloor, 1 − scaleRange·easeOutQuad(p)),  easeOutQuad(p) = 1−(1−p)²
    func center(for t: CGPoint) -> CGPoint
    // x: initialCenter.x + t.x (완전 추종)
    // y: initialCenter.y + (t.y ≥ 0 ? t.y : rubberBand(t.y, H))  (위쪽은 러버밴드)
    func cornerProgress(forProgress p: CGFloat) -> CGFloat   // = min(1, p / rampEnd)

    func shouldComplete(progress p: CGFloat, velocity v: CGPoint, translation t: CGPoint) -> Bool
    // d̂ = ‖t‖ < 10 ? (0,1) : t/‖t‖ ;  vR = v·d̂
    // vR > 500 → true; vR < −500 → false
    // else: projected = (vR/1000)·rate/(1−rate), rate = 0.998 (WWDC 2018 projection)
    //       return p + projected/span > 0.5
}
```

**Spring 변환 (Support/SpringConverter or ZoomTransition.Spring 내부):**

```
ω  = 2π / response
k  = ω²                       (mass = 1)
c  = 2 · dampingRatio · ω
UISpringTimingParameters(mass: 1, stiffness: k, damping: c, initialVelocity: v⃗)
v⃗ = 축별 (제스처 속도 / max(남은 이동 거리, 1))   // settle 스프링에만 비영
UIViewPropertyAnimator(duration: response, timingParameters: ...)  // 스프링은 duration 무시
```

### 5.3 SourceViewResolver

```swift
struct ResolvedSource {
    let view: UIView
    let rectInContainer: CGRect          // presentation layer 우선 (§7.5)
    let visibleRectInContainer: CGRect
    let cornerRadius: CGFloat
    let placard: UIView?                 // snapshotView(afterScreenUpdates: false), nil 허용
}

enum ResolutionFailure: Equatable {
    case providerNil, detached, insideZoomedHierarchy, hiddenAncestor,
         insufficientVisibility(ratio: CGFloat), offContainer
}

@MainActor
enum SourceViewResolver {
    static func resolve(provider: ZoomTransition.SourceViewProvider,
                        context: ZoomTransition.Context,
                        zoomedView: UIView,
                        containerView: UIView) -> Result<ResolvedSource, ResolutionFailure>
}
```

검증 사다리(순서 고정, 양방향 동일 — §7.5에 상세): providerNil → window nil → 목적지 계층 소속(assert) → 조상 hidden/alpha<0.01 → presentation-layer rect 변환 → visible-rect 비율 < 0.35 → 컨테이너 교차. 실패 → `.fellBack(.sourceUnresolved)` 폴백.

### 5.4 RestorationToken

```swift
@MainActor
final class RestorationToken {
    func record(_ restore: @escaping () -> Void)   // 뷰는 반드시 weak 캡처
    func restore()                                  // 멱등 (didRestore 플래그)
    deinit { /* restore() — 버려진 컨텍스트 백스톱 */ }
}
```

기록 대상: 소스 `isHidden` 원값, 탭바/툴바 `alpha`, `additionalSafeAreaInsets` 원값, 스크롤뷰 `isScrollEnabled`, presenter `transform`.

### 5.5 PortalView

```swift
final class PortalView: UIView {
    let contentContainer = UIView()       // 라이브 목적지 뷰 호스트
    var placardView: UIView?              // 소스 스냅샷, 옵셔널
    var portalCornerRadius: CGFloat       // layer.cornerRadius + cornerCurve = .continuous,
                                          // set 시 min(bounds.width, bounds.height)/2 클램프
    // clipsToBounds = true 고정. visibleRect 클립이 필요하면 최종 상태에서 bounds 조정(§7.5).
}
```

### 5.6 TransitionDriver (`UIViewControllerAnimatedTransitioning`)

- `transitionDuration` = `configuration.spring.response`.
- `animateTransition(using:)`: setup(§7.1/§7.2) → animator 2개 생성·시작(비인터랙티브). **`interruptibleAnimator(using:)`는 구현하지 않는다**(§14-정제 1).
- `animationEnded(_:)`: `didCleanUp == false`면 `forceFinish(.abandoned)` 경로로 cleanup (UIKit이 컨텍스트를 버린 경우의 최후 방어선).
- **완료 배리어**: `ActiveTransition.pendingAnimatorCount`를 animator 생성 시 증가, 각 완료 블록에서 감소, 0 도달 시 `stateMachine.handle(.allAnimatorsFinished)` → cleanup → `completeTransition(!ctx.transitionWasCancelled)`.

### 5.7 ZoomInteractionDriver (`UIViewControllerInteractiveTransitioning` + 제스처)

- `var wantsInteractiveStart: Bool` — 제스처 개시 여부로 동적 설정.
- 팬 제스처: 목적지 root view에 설치(`interactiveDismissal == .pan`), `UIGestureRecognizerDelegate`:
  - `gestureRecognizerShouldBegin`: 하향 지배적 translation ∧ (자동 탐색된 최상위 `UIScrollView`가 top에서 정지 ∨ 스크롤뷰 없음) ∧ `state == .idle`(신규 개시) 또는 `state ∈ {animating, settling}`(grab).
  - 시작 시 스크롤뷰 `isScrollEnabled = false` (토큰 기록).
- edge-swipe: §7.4.
- settle 순서(정확히 이 순서 — 어기면 내비바 보간 깨짐):
  1. `ctx.finishInteractiveTransition()` 또는 `ctx.cancelInteractiveTransition()` — **continuation 시작 시점에 호출**
  2. 취소면 `transitionAnimator.isReversed = true` **먼저**, 그 다음 `continueAnimation(withTimingParameters: nil, durationFactor: 취소 ? f : 1−f)`
  3. 소스 **재해석**(settle-time) → geometry 스프링 fresh 생성(initialVelocity 반영) → 시작
  4. 배리어가 completeTransition 발화

### 5.8 ModalTransitioningAdapter / ZoomPresentationController

**Adapter** (`UIViewControllerTransitioningDelegate`, internal, ZoomTransition이 소유):
- `animationController(forPresented/forDismissed)`: 가드 체인 — `state != .idle` → nil + `.fellBack(.reentrant)`; Reduce Motion/VO(§9) → CrossDissolve driver; 아니면 TransitionDriver.
- `interactionControllerForDismissal`: `interactiveDismissal == .pan`이면 driver(wantsInteractiveStart는 제스처 활성 여부), 아니면 nil.
- `interactionControllerForPresentation`: driver(wantsInteractiveStart = false) — 확대 중 grab을 합법화.
- `presentationController(forPresented:)`: style이 `.custom`일 때만 ZoomPresentationController.

**ZoomPresentationController**:
- `shouldRemovePresentersView = false`.
- 디밍 뷰 소유(alpha 애니메이션은 transition animator가 수행).
- `presentationTransitionWillBegin`: `resignsFirstResponders`면 presenter `endEditing(true)`; presented에 `modalPresentationCapturesStatusBarAppearance = true`; `accessibilityViewIsModal` 설정.
- `containerViewWillLayoutSubviews`: `isTransitioning` 가드 — 전환 중 frame 스탬핑 금지. 회전 시 presenter push-back은 transform=identity → frame 적용 → transform 재적용.
- `viewWillTransition(to:with:)`: 전환 중이면 `forceFinish(.sizeChange)`.
- `accessibilityPerformEscape()` → `presentedViewController.dismiss(animated: true)` → true.

### 5.9 ZoomAnimator / CrossDissolveAnimator (internal Strategy)

`ZoomTransitionAnimating` 프로토콜(internal, 설계 문서와 동일 형태: prepare / makeAnimators / finish + `ZoomAnimationContext`). `ZoomAnimator`가 §7의 choreography 구현체. `CrossDissolveAnimator`: 목적지 alpha 페이드(+ 폴백 dismiss 시 중앙으로 85% 축소), 폴백·Reduce Motion·VO 공용.

---

## 6. Choreography 상세

### 6.1 컨테이너 스택 (아래→위)

```
[push] fromView (또는 modal .custom: presenter 뷰 — 컨테이너 밖, 생존)
[push 전용] 디밍 뷰 (driver 소유; modal은 presentation controller 소유)
바 스냅샷 (해당 시)
PortalView
  ├─ contentContainer ── 라이브 목적지 뷰 (finalFrame으로 선레이아웃, transform 스케일)
  └─ placardView (옵셔널)
```

### 6.2 애니메이터 소유 속성 분담 (불변 규칙)

| transition animator (대칭·역전 안전 속성만) | geometry animator (kill & rebuild 자유) |
|---|---|
| 디밍 alpha 0↔1 | portal.frame / center / bounds |
| presenter push-back transform ↔ identity (scale 0.94) | contentContainer 내 라이브 뷰 transform |
| placard alpha (keyframes: appearing 앞 40% 페이드아웃 / disappearing 뒤 30% 페이드인) | |
| portal cornerRadius (모프) | |
| 바 스냅샷 alpha | |

- transition animator: pause / fraction 스크럽(≤ 0.995) / isReversed / continue 허용. **역방향 실행 중 스크럽 금지** — 그 경우 freeze-and-rebuild(§7.7).
- geometry animator: 언제든 `stopAnimation(false)` + `finishAnimation(at: .current)`로 죽이고 재생성.

### 6.3 cornerRadius

- 값 읽기는 항상 `layer.presentation()?.cornerRadius ?? layer.cornerRadius`.
- `.automatic`: from = 소스 layer.cornerRadius(presentation), to = §6.5 컨테이너 문맥 radius.

### 6.4 Safe area 고정

setup에서 `zoomedVC.additionalSafeAreaInsets`에 최종 지오메트리 기준 인셋을 주입(토큰 기록), cleanup에서 원복 — 스케일 비행 중 인셋 요동으로 인한 내부 재레이아웃 차단.

### 6.5 컨테이너 문맥 radius (Support/ContainerCornerRadius)

`UIScreen.main` 금지. 규칙: containerView.bounds == window.bounds ∧ window.bounds == screen.bounds(해당 window의 screen)일 때만 디바이스 코너 추정값(기종 테이블 없이 `UIScreen.value(forKey:)` 같은 private API 금지 — 보수적 상수 세트: 노치/다이내믹아일랜드 기기 ≈ 47~55pt는 근사 불가하므로 **default 39pt 상수 + `.fixed` 이스케이프 해치**, README 명시), 그 외(스플릿뷰·시트 내부) = 0.

---

## 7. 시퀀스 명세

### 7.1 S1 — 비인터랙티브 zoom-in (present / push)

1. (modal) `present()` → adapter 가드 체인 통과 → TransitionDriver + presentation driver vend. (push) 프록시 vend 규칙 §7.3.
2. `stateMachine.handle(.begin(.zoomIn, interactive: false))`.
3. `delegate.willBegin` 호출 → **그 후** 소스 해석(appearing). 실패 → CrossDissolve로 전환(§8).
4. setup: `endEditing`(config) → `containerView.addSubview(toView)`, `toView.frame = ctx.finalFrame(for: toVC)`, `layoutIfNeeded()` → safe-area 주입 → (push) 디밍 뷰 추가 → 바 스냅샷(§7.8) → portal 생성 `frame = sourceRect`, `cornerRadius = sourceCornerRadius` → 라이브 toView를 `portal.contentContainer`로 reparent + `contentScale` transform(top-center 앵커) → placard 부착(성공 시) → 소스 hide(토큰).
5. 두 animator 생성(§6.2 분담, 동일 spring)·시작. `pendingAnimatorCount = 2`.
6. 배리어 0 도달 → `.allAnimatorsFinished` → cleanup(§7.9, finished) → `completeTransition(true)` → `didEnd(.init(isCompleted: true, wasInteractive: false, fallbackReason: nil))`.

### 7.2 S2 — 비인터랙티브 zoom-out (dismiss / pop)

1. 가드/begin/willBegin → 소스 **재해석**(disappearing).
2. 배경 준비: (push) `toView`를 fromView 아래 finalFrame으로 삽입 + `layoutIfNeeded()`. (modal `.custom`) presenter 생존 — 작업 없음. (`.fullScreen`) `ctx.view(forKey: .to)` non-nil — 최하단 삽입 + `layoutIfNeeded()` **후** 소스 해석. (`.overFullScreen`) `view(forKey: .to)` nil 허용 — presenter가 이미 있음.
3. portal을 현재 fromView frame으로 생성, 라이브 fromView reparent(identity), placard alpha 0 부착, 소스 hide(토큰).
4. animator 2개 생성·시작 (geometry: portal → `sourceVisibleRect` 반영 rect). 이후 S1과 동일.
5. **취소 시 복구 불변식**(cleanup에서): fromView를 컨테이너로 reparent, `transform = .identity`, `frame = ctx.finalFrame(for: fromVC)` 재스탬프.

### 7.3 Navigation vend 규칙 (프록시 `animationControllerFor`)

```
operation == .push:
    toVC.zoomTransition != nil ∧ state == .idle          → vend (pushPredecessor = fromVC 기록)
operation == .pop:
    fromVC.zoomTransition != nil ∧ toVC === fromVC.zoomTransition.pushPredecessor ∧ state == .idle → vend
그 외 (다단 pop, setViewControllers, predecessor 불일치)  → downstream 위임 or nil + .fellBack(.unsupportedOperation)
```

DEBUG 진단: push되는 VC가 `zoomTransition != nil`인데 이 프록시를 거치지 않았음을 `didShow` 훅에서 감지 → `os_log` + `.fellBack(.notWired)`.

### 7.4 S3 — edge-swipe pop 배선

1. `didShow`에서 top VC가 `zoomTransition` 보유 시: `nav.interactivePopGestureRecognizer`에 우리 target/action 추가(1회), 그 delegate를 우리 arbitrator로 교체(원 delegate 참조 보관).
2. arbitrator `gestureRecognizerShouldBegin`: top VC가 zoom 보유 ∧ `state == .idle` ∧ `nav.viewControllers.count > 1` → true(우리 경로). zoom 미보유 → **원 delegate에 위임** (스톡 pop 생존).
3. `.began`: `gestureInitiated = true` → `nav.popViewController(animated: true)` → 프록시 vend → `interactionControllerFor` → driver(`wantsInteractiveStart = true`).
4. `.changed` 이후는 S4의 4~5와 동일(edge translation을 FollowModel에 공급).

### 7.5 소스 해석 사다리 (양방향, begin과 settle에서 각각 실행)

```
1. provider(context) 호출 (main-thread assert)          nil → .providerNil
2. view.window == nil                                   → .detached
3. view.isDescendant(of: zoomedView)                    → assert + .insideZoomedHierarchy
4. 조상 워크: isHidden ∨ alpha < 0.01                    → .hiddenAncestor
5. rect: layer.animationKeys() 비어있지 않으면 presentation layer frame,
   superview 좌표 → containerView로 convert
6. visibleRect: clipsToBounds/masksToBounds 조상마다 교차 → 비율 < 0.35 → .insufficientVisibility
7. rect ∩ container.bounds.insetBy(-8) == ∅              → .offContainer
8. 성공: placard 스냅샷 시도(nil 허용) → ResolvedSource
```

### 7.6 S4 — 제스처 개시 인터랙티브 dismiss

1. 팬 `.began`(§5.7 게이트 통과) → `endEditing` → `dismiss`/`popViewController` 호출 → driver `wantsInteractiveStart = true`로 vend.
2. `startInteractiveTransition(ctx)`: S2의 setup 수행하되 **geometry animator는 만들지 않고**, transition animator를 **paused at 0**으로 생성. FollowModel 시드(initialCenter = portal.center). `stateMachine.begin(.zoomOut, interactive: true)`.
3. `.changed`: `p = follow.progress(t)` → portal.center/scale/cornerProgress 직접 적용, `transitionAnimator.fractionComplete = min(p, 0.995)`, `ctx.updateInteractiveTransition(p)`.
4. `.ended/.cancelled`: `c = follow.shouldComplete(p, v, t)` → `stateMachine.release(toCompleted: c)` → §5.7 settle 순서 실행.
5. 배리어 → cleanup → `completeTransition(c)`.

**fast-forward 방향 규칙**: interactive 중 forceFinish → `p > 0.5 ? 완료 : 취소`. settling 중 → 이미 커밋된 방향. animating 중 → 완료.

### 7.7 S5 — grab (mid-flight / settle 중 재잡기)

`freezeGeometryAndPauseTransition` 사이드이펙트의 구현:

1. 모든 geometry animator: `stopAnimation(false)` → `finishAnimation(at: .current)` (presentation 값이 model에 스탬핑, 목록에서 제거).
2. transition animator:
   - 정방향 실행/일시정지 → `pauseAnimation()`. `ctx.pauseInteractiveTransition()` (비인터랙티브로 시작된 전환의 합법적 인터랙티브 전환).
   - **역방향(취소 settle) 실행 중** → 스크럽 금지 규칙: `stopAnimation(false)` + `finishAnimation(at: .current)` → 현재 model 값 → 목표 값으로 **fresh transition animator**를 paused at 0으로 재생성, `baseProgress` 보관(이후 fraction = remap(p)).
3. FollowModel 재시드: `initialCenter = portal.layer.presentation()?.position ?? portal.center`.
4. 이후 S4의 3~5와 동일. zoom-in grab 후 되던지기 = release(toCompleted: false) → present 취소 → cleanup에서 toView 컨테이너에서 완전 제거 + 소스 unhide → `completeTransition(false)`.

### 7.8 바 / status bar

- 탭바(`hidesBottomBarWhenPushed`)·툴바: `snapshotView(afterScreenUpdates: false)`를 컨테이너의 바 위치에 삽입(fromView 위 / portal 아래), 실제 바 `alpha = 0`(토큰), 스냅샷 alpha는 transition animator. 스냅샷 nil이면 전부 생략.
- 내비바: 기본 권장 = detail 숨김(Example 시연). 양쪽 표시 시 정직한 progress 보고에 의존하되, **취소된 인터랙티브 pop 완료 후 `navigationBar.setNeedsLayout()`** 강제(iOS 15 고스팅 워크어라운드).
- status bar: modal은 `modalPresentationCapturesStatusBarAppearance = true` + animator 블록 내 `setNeedsStatusBarAppearanceUpdate()`, 취소 시 블록 밖 재호출. push는 라이브러리가 해결 불가(`childForStatusBarStyle` README 캐비앗 + Example 시연).

### 7.9 단일 출구 cleanup

```swift
func cleanup(finished: Bool) {
    guard !active.didCleanUp else { return }; active.didCleanUp = true
    restorationToken.restore()                      // 소스 unhide, 바 alpha, safe-area, scroll, presenter transform
    // 라이브 뷰 복귀:
    //   finished(zoom-in): toView → container, transform=identity, frame=finalFrame
    //   cancelled(zoom-out): fromView → container, transform=identity, frame=finalFrame(재스탬프)
    //   finished(zoom-out): UIKit이 fromView 제거 — reparent만 해제
    portal.removeFromSuperview(); 스냅샷·디밍(푸시) 제거
    UIAccessibility.post(notification: .screenChanged, argument: 도착 화면 첫 요소)
    activeTransition = nil                          // 애니메이터/컨텍스트 해제 지점
    // 이후 호출자가 completeTransition → didEnd 보고
}
```

호출 지점 우선순위: 배리어 완료 → `animationEnded` → forceFinish → `deinit`.

### 7.10 forceFinish 공통 절차

1. 팬 recognizer `isEnabled = false; isEnabled = true` (제스처 플러시).
2. 인터랙티브 보고 중이었으면 `finish/cancelInteractiveTransition` (방향 규칙 §7.6).
3. 모든 live animator: `state == .active`일 때만 `stopAnimation(false)` + `finishAnimation(at: 방향)` (`.inactive`/`.stopped` 가드 — 예외 방지).
4. cleanup(방향) → `completeTransition`.

트리거: `viewWillTransition`(modal) / 컨테이너 bounds-change 감시(push — 컨테이너에 zero-size 레이아웃 센티널 뷰) / `UIScene.didEnterBackgroundNotification`(containerView의 windowScene 필터) / `animationEnded`(abandoned).

---

## 8. 폴백 경로

`FallbackReason` 발생 → 같은 TransitionDriver가 Strategy만 `CrossDissolveAnimator`로 교체해 실행(상태 머신·배리어·cleanup 공유). dismiss 폴백의 시각: 중앙으로 85% 축소 + 크로스페이드 + 디밍 페이드. `fallback == .systemDefault`(modal 한정): animation controller에서 nil을 반환할 기회가 이미 지난 경우가 있으므로 **modal은 crossDissolve로 통일**, nav는 vend 시점에 nil 반환으로 시스템 애니메이션 (README 명시).

---

## 9. 접근성 / 환경

| 조건 | 동작 |
|---|---|
| `isReduceMotionEnabled ∨ prefersCrossFadeTransitions` (respectsReduceMotion) | CrossDissolve 단락, `.fellBack(.reduceMotion)` |
| `isVoiceOverRunning` | 비인터랙티브 CrossDissolve + 팬 미설치 |
| 항상 | presentation controller `accessibilityViewIsModal`, cleanup `.screenChanged`, `accessibilityPerformEscape` |

---

## 10. 진단 (DEBUG 전용)

- `os_log(.debug, log: .zoomy, ...)`: vend 거부 사유, 소스 해석 실패 단계, 프록시 미배선 감지, downstream 교체 감지.
- `assertionFailure` 목록: set-after-present, 이중 부착, provider가 목적지 서브뷰 반환, provider 내 재진입 내비게이션, 프록시 체인 순환, 불법 상태 전이, sheet/popover 스타일.
- release 빌드: 전부 조용한 폴백/no-op (크래시 금지 원칙).

---

## 11. 테스트 명세 (Tests/ZoomyTests/)

**pure (호스트 앱 불필요):**
- `ZoomGeometryTests`: portalRect/cornerRadius lerp @ {0, 0.5, 1, 1.15(오버슈트)}, radius 클램프, contentScale, rubberBand 단조성·경계.
- `FollowModelTests`: progress — 수직만/수평만/대각/음수 y, scale 바닥, center 러버밴드, cornerProgress 램프. `shouldComplete` 테이블: (p, v, t) 그리드 — 하향 플릭 / 상향 플릭 / **가로 플릭(vR 투영이 완료 판정)** / 저속 경계 0.5.
- `TransitionStateMachineTests`: 전이 테이블 전수(표의 모든 셀), 불법 전이 assert 훅 검증, **퍼지**: 랜덤 이벤트 1,000시퀀스에서 cleanupAndComplete ≤ 1/begin.
- `SpringConverterTests`: response→stiffness/damping 수치( response 0.44, ζ 0.85 → k≈203.9, c≈24.3 ), initialVelocity 정규화.

**hosted (UIWindow + mock `UIViewControllerContextTransitioning`):**
- `MockTransitionContext`: `updateInteractiveTransition/finish/cancel/completeTransition` 호출 기록.
- `CallOrderTests`: S1/S2/S4 완료·취소·grab-후-취소·forceFinish 각각 — `completeTransition` 정확 1회·플래그 일치, 소스 unhide, 컨테이너 잔존 서브뷰 0, cancel 후 fromView transform==identity ∧ frame==finalFrame.
- `SourceResolverTests`: 사다리 6단계 각각의 실패 재현(hidden 조상, 65% 클립, 목적지 서브뷰, 스크롤아웃), presentation-layer 분기.
- `DelegateProxyTests`: 포워딩 매트릭스(willShow/didShow/지원 안 하는 셀렉터), downstream 사후 교체 → capability 재보고, downstream dealloc 후 stale 셀렉터 → 무크래시, 순환 가드, 인접성 vend 규칙(popToRoot/setViewControllers/다단 → nil).
- `MemoryTests`: 목적지 dealloc 후 transition/driver/portal weak 전부 nil, RestorationToken deinit 복원, 50회 반복 leak 없음(weak 배열 검사).

**Example 수동 QA 체크리스트**: 설계 문서 Verification 절 그대로 (확대 중 되던지기, settle 재잡기, 스크롤아웃/reloadData dismiss, 반쯤 가린 셀, 회전×{후, 제스처 중}, 가로 플릭, 키보드, Reduce Motion/VO, 롱프레스 다단 pop, iPad 멀티윈도우, 양쪽 내비바, hidesBottomBarWhenPushed, 더블탭, 메모리 그래프).

---

## 12. Example 앱 명세

- 탭 1 **Push**: 사진 그리드(UICollectionView, diffable, 안정 ID) → detail push. 내비바 숨김 데모 + `childForStatusBarStyle` 오버라이드.
- 탭 2 **Modal**: 동일 그리드 → present. 딤·코너 커스텀 데모.
- 탭 3 **Torture**: 스크롤아웃 후 dismiss 버튼 / reloadData 버튼 / 키보드 열고 present / hidesBottomBarWhenPushed / 반쯤 가린 셀 타깃.

---

## 13. 마일스톤 ↔ 파일 ↔ 완료 기준

| # | 마일스톤 | 파일 | 완료 기준 |
|---|---|---|---|
| 1 | 스캐폴드 | Package.swift, 폴더, Example 골격 | `swift build` 성공, Example 빈 그리드 구동 |
| 2 | Pure core (TDD) | ZoomGeometry, TransitionStateMachine, Spring 변환 | §11 pure 테스트 전부 green |
| 3 | Modal 비인터랙티브 | PortalView, ZoomAnimator, PresentationController, Adapter, setter, RestorationToken, SourceViewResolver | Example 탭2 present/dismiss 정상, S1/S2 CallOrder 테스트 green |
| 4 | Navigation | ZoomNavigationDelegate, UINavigationController ext | 탭1 push/pop 정상, DelegateProxyTests green |
| 5 | Edge-swipe 배선 | ZoomInteractionDriver(부분) | 엣지 스와이프로 zoom pop, non-zoom 화면 스톡 동작 보존 |
| 6 | 인터랙티브 dismiss | ZoomInteractionDriver 완성 | S4/S5 시나리오 수동 확인 + CallOrder green |
| 7 | 엣지케이스+접근성 | forceFinish, 바 스냅샷, a11y, scene 관찰 | Torture 탭 + QA 리스트 통과 |
| 8 | 마감 | README, 문서 | QA 전수 + 메모리 그래프 클린 |

각 마일스톤 완료 시 커밋. 2번은 테스트 먼저(TDD).

---

## 14. 설계 문서 대비 정제 사항 (구현 중 발견된 모순의 사전 해소)

1. **`interruptibleAnimator(using:)` 미구현**: 이 메서드는 percent-driven 인터랙션에서 UIKit이 애니메이터를 직접 구동할 때 필요하며 "전환 수명 동안 동일 인스턴스" 계약이 붙는다. 우리는 커스텀 `UIViewControllerInteractiveTransitioning`으로 애니메이터를 전적으로 자가 구동하므로 vend하지 않는다 → grab 시 freeze-and-rebuild(§7.7)가 계약 위반 없이 합법화된다. (설계 문서의 동일-인스턴스 규칙 언급은 percent-driven 전제였음.)
2. **geometry를 항상 별도 애니메이터로 분리** (비인터랙티브 포함): 설계는 "비인터랙티브는 한 애니메이터에 동승"이었으나, grab 시 '동승한 geometry가 든 paused 애니메이터에 직접 기하를 쓰면 CAAnimation과 충돌'하는 문제가 생긴다. 두 애니메이터를 항상 분리하고 완료를 배리어로 묶으면 모든 경로가 동일한 코드를 탄다.
3. **`Result`를 enum에서 struct로**: `.fellBack`이면서 동시에 completed/cancelled인 상태가 존재(폴백 애니메이션도 완료/취소된다) — 직교 필드로 분리.
4. **`fallback: .systemDefault`는 nav 전용 의미**: modal은 animation controller 교체 시점이 지나 시스템 복귀 불가 → crossDissolve로 통일(§8).
5. **디바이스 코너 radius**: private API 없이 정확값 획득 불가 → 보수적 기본 상수 + `.fixed` 이스케이프 해치로 명세(§6.5).

## 15. 오픈 이슈 (구현 전 확인 권장)

- [ ] 모듈명 `Zoomy` vs 저장소명 `ZoomTransition` 유지 여부 — 모듈을 `ZoomTransition`으로 하려면 핵심 클래스명 변경 필요(예: `ZoomTransitionController`).
- [ ] FollowModel 상수(kX=0.5, span=0.55H, scaleFloor=0.55)는 시뮬레이터 튜닝 대상 — 마일스톤 6에서 실기기 감각으로 조정.
- [ ] 내비바 양쪽 표시 + large title 조합의 바 스냅샷 전략은 마일스톤 7에서 실측 후 채택/포기 결정(포기 시 "detail 바 숨김 필수"로 문서 강등).
