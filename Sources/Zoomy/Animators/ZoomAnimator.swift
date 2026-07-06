import UIKit
import ZoomyCore

/// The real zoom choreography (`docs/TECH_SPEC.md` §6/§7): flies a `PortalView` between the
/// resolved source rect and the destination's final frame while the live view counter-scales
/// inside it, morphing corner radius, dimming, presenter push-back, and a source-snapshot
/// placard along the way.
///
/// Property ownership follows the §6.2 split verbatim: the *transition* animator carries only
/// scrub/reverse-safe properties (dimming alpha, presenter push-back, placard keyframes, corner
/// morph, status-bar update); the *geometry* animator carries the portal frame and the live
/// view's counter-scale. Both are always separate, even here in the non-interactive path, so
/// M6's grab can kill and rebuild the geometry animator alone (TECH_SPEC §14-2).
///
/// ### Interactive-capable helpers (M6, §7)
/// `makeAnimators` (non-interactive) is expressed as `makeTransitionAnimator` + a corner morph +
/// `makeGeometryAnimators`; the `ZoomInteractionDriver` reuses those same helpers to build a
/// paused-at-0 transition animator up front and fresh geometry springs at settle time.
/// `prepareInteractive` stages the disappearing views without building any animator, and
/// `applyInteractiveFollow` scrubs the staged portal/live-view directly from a `FollowModel`
/// output while a pan gesture is in flight.
///
/// ### Top-center anchoring — judgment call
/// The brief specifies a "top-center anchor effect" achieved by scaling the live view and then
/// correcting `frame.origin`. Mutating `frame` *while a transform is applied* is unsupported by
/// UIKit (frame is derived from bounds+center+transform, and animating it alongside the
/// transform corrupts both). This implementation realises the identical visual by animating the
/// UIKit-supported animatable pair `center` + `transform` instead: with the live view's bounds
/// frozen at the final size, a scale of `s` and a center of `(finalW·s/2, finalH·s/2)` pins the
/// top edge to y=0 and horizontally centers the view; because portal frame, live-view center,
/// and live-view scale all interpolate on the *same* spring, the view stays top-centered and
/// exactly portal-width for the whole flight. See the report for the geometry derivation.
@MainActor
final class ZoomAnimator: ZoomTransitionAnimating {

    /// Presenter push-back scale while a modal `.custom` destination is on top (§6.2).
    private static let presenterPushBack = CGAffineTransform(scaleX: 0.94, y: 0.94)

    /// Placard cross-fade timing as a fraction of the animator timeline (§3 table).
    private static let appearingPlacardFadeOutEnd: Double = 0.4
    private static let disappearingPlacardFadeInStart: Double = 0.7

    func prepare(using context: ZoomAnimationContext) {
        guard let source = context.resolvedSource, let geometry = context.geometry else {
            // ZoomAnimator is only ever selected when the source resolved; defend anyway.
            ZoomyAssert.fail("ZoomAnimator.prepare called without a resolved source")
            context.containerView.addSubview(context.zoomedView)
            context.zoomedView.frame = context.finalFrame
            return
        }

        switch context.phase {
        case .appearing: prepareAppearing(context, source: source, geometry: geometry)
        case .disappearing: prepareDisappearing(context, source: source, geometry: geometry)
        }
    }

    func makeAnimators(
        using context: ZoomAnimationContext
    ) -> (transition: UIViewPropertyAnimator, geometry: [UIViewPropertyAnimator]) {
        // The non-interactive path is exactly `makeTransitionAnimator` + the corner morph (which
        // the interactive path drives directly, hence its being added here rather than inside the
        // shared helper) + a single geometry spring to the phase's resting rect.
        let transitionAnimator = makeTransitionAnimator(using: context)
        addCornerMorph(to: transitionAnimator, using: context)

        let targetRect: CGRect
        switch context.phase {
        case .appearing: targetRect = context.finalFrame
        case .disappearing: targetRect = context.geometry?.sourceRect ?? context.finalFrame
        }
        let geometry = makeGeometryAnimators(
            using: context, targetPortalRect: targetRect, initialVelocity: .zero
        )
        return (transitionAnimator, geometry)
    }

    func finish(using context: ZoomAnimationContext, completed: Bool) {
        let portal = context.portal
        let zoomedView = context.zoomedView

        switch (context.phase, completed) {
        case (.appearing, true):
            // Land the live view back in the container at its resting frame.
            context.containerView.addSubview(zoomedView)
            zoomedView.transform = .identity
            zoomedView.frame = context.finalFrame
            portal.removeFromSuperview()

        case (.disappearing, true):
            // The destination is going away — removing the portal removes the hosted live view.
            portal.removeFromSuperview()

        case (.appearing, false):
            // Interactive present grab thrown back (M6): remove the never-committed destination.
            zoomedView.removeFromSuperview()
            portal.removeFromSuperview()

        case (.disappearing, false):
            // Cancelled dismiss (M6): restore the live view to its resting position — this is the
            // cancel-recovery invariant (identity transform + finalFrame) the call-order tests assert.
            context.containerView.addSubview(zoomedView)
            zoomedView.transform = .identity
            zoomedView.frame = context.finalFrame
            portal.removeFromSuperview()
        }
    }

    // MARK: - Interactive hooks (M6, §7)

    /// Interactive disappearing setup: portal creation, reparenting, source hide, dimming/presenter
    /// staging — everything `prepareDisappearing` does — *without* building any animator (the driver
    /// creates a paused transition animator itself and fresh geometry springs at settle time).
    func prepareInteractive(using context: ZoomAnimationContext) {
        guard context.phase == .disappearing else {
            ZoomyAssert.fail("prepareInteractive is only valid for a disappearing (dismiss/pop) transition")
            return
        }
        guard let source = context.resolvedSource, let geometry = context.geometry else {
            ZoomyAssert.fail("prepareInteractive called without a resolved source")
            return
        }
        prepareDisappearing(context, source: source, geometry: geometry)
    }

    /// Builds the scrub/reverse-safe transition animator (dimming, presenter push-back, placard,
    /// status bar) with no geometry and no corner morph — the driver drives corner directly from
    /// `cornerProgress` while following the finger. Returned in the `.inactive` state; the caller
    /// pauses it to arm scrubbing.
    func makeTransitionAnimator(using context: ZoomAnimationContext) -> UIViewPropertyAnimator {
        let animator = makeSpringAnimator(context.configuration.spring)
        switch context.phase {
        case .appearing: configureAppearingTransition(context, animator)
        case .disappearing: configureDisappearingTransition(context, animator)
        }
        return animator
    }

    /// Builds the geometry spring that flies the portal (and counter-scales the live view) from its
    /// current staged state to `targetPortalRect`. Used by the non-interactive `makeAnimators` (to
    /// the resting rect, zero velocity) and by the driver's settle (to the re-resolved source rect
    /// or the final frame, seeded with the release velocity).
    func makeGeometryAnimators(
        using context: ZoomAnimationContext,
        targetPortalRect: CGRect,
        initialVelocity: CGVector
    ) -> [UIViewPropertyAnimator] {
        let spring = context.configuration.spring
        let timing = SpringConverter.timingParameters(
            response: spring.response,
            dampingRatio: spring.dampingRatio,
            initialVelocity: initialVelocity
        )
        let animator = UIViewPropertyAnimator(duration: spring.response, timingParameters: timing)

        let portal = context.portal
        let zoomedView = context.zoomedView
        let finalSize = context.finalFrame.size
        let scale = (finalSize.width != 0) ? (targetPortalRect.width / finalSize.width) : 1

        animator.addAnimations {
            portal.frame = targetPortalRect
            zoomedView.transform = CGAffineTransform(scaleX: scale, y: scale)
            zoomedView.center = self.scaledTopCenter(finalSize: finalSize, scale: scale)
        }
        return [animator]
    }

    /// Directly applies one finger-follow frame to the staged portal/live-view (§ interactive
    /// `.changed`): the portal is sized `finalSize · scale` and centered under the finger, the live
    /// view counter-scales top-centered to fill it, and the corner radius lerps final→source by
    /// `cornerProgress`. No animation — a straight model-layer write per gesture sample.
    func applyInteractiveFollow(
        using context: ZoomAnimationContext,
        scale: CGFloat,
        center: CGPoint,
        cornerProgress: CGFloat
    ) {
        guard let geometry = context.geometry else { return }
        let portal = context.portal
        let zoomedView = context.zoomedView
        let finalSize = context.finalFrame.size

        let portalSize = CGSize(width: finalSize.width * scale, height: finalSize.height * scale)
        portal.frame = CGRect(
            origin: CGPoint(x: center.x - portalSize.width / 2, y: center.y - portalSize.height / 2),
            size: portalSize
        )
        zoomedView.transform = CGAffineTransform(scaleX: scale, y: scale)
        zoomedView.center = scaledTopCenter(finalSize: finalSize, scale: scale)

        let corner = geometry.finalCornerRadius
            + (geometry.sourceCornerRadius - geometry.finalCornerRadius) * cornerProgress
        portal.portalCornerRadius = corner
    }

    // MARK: - Appearing (present)

    private func prepareAppearing(
        _ context: ZoomAnimationContext,
        source: ResolvedSource,
        geometry: ZoomGeometry
    ) {
        let container = context.containerView
        let zoomedView = context.zoomedView
        let portal = context.portal

        // 1. Host the live view at its final frame and lay it out once, so its internal layout
        //    is frozen for the whole flight (only a transform moves after this).
        container.addSubview(zoomedView)
        zoomedView.autoresizingMask = []
        zoomedView.frame = context.finalFrame
        container.layoutIfNeeded()

        // 3. Portal at the source rect, corner at the source radius.
        container.addSubview(portal)
        portal.frame = source.rectInContainer
        portal.portalCornerRadius = geometry.sourceCornerRadius

        // 4. Reparent into the portal and counter-scale to portal width, top-center anchored.
        portal.contentContainer.addSubview(zoomedView)
        zoomedView.frame = CGRect(origin: .zero, size: context.finalFrame.size)
        let scale = geometry.contentScale(portalWidth: portal.bounds.width)
        zoomedView.transform = CGAffineTransform(scaleX: scale, y: scale)
        zoomedView.center = scaledTopCenter(finalSize: context.finalFrame.size, scale: scale)

        // 2. Safe-area pin — injected *after* reparenting (judgment call, see report): inside the
        //    small portal the inherited insets are already 0, so injecting the window insets as
        //    `additional` keeps the total equal to the value the frozen layout used, with no
        //    double application. Injecting before reparenting (while still full-screen, inherited
        //    == window insets) would momentarily double them.
        let windowInsets = container.window?.safeAreaInsets ?? .zero
        context.restorationToken.recordAdditionalSafeAreaInsets(of: context.zoomedViewController)
        context.zoomedViewController.additionalSafeAreaInsets = windowInsets

        // 5. Placard on top (alpha 1 → fades out early), source hidden.
        if let placard = source.placard {
            placard.alpha = 1
            portal.placardView = placard
        }
        context.restorationToken.recordHide(of: source.view)
        source.view.isHidden = true

        // 6. Dimming starts clear; presenter starts at identity (records for restore).
        context.dimmingView?.alpha = 0
        if let presenter = context.presenterView {
            context.restorationToken.recordTransform(of: presenter)
            presenter.transform = .identity
        }

        // Flush initial state to the presentation layers before animators capture "from" values.
        container.layoutIfNeeded()
    }

    private func configureAppearingTransition(
        _ context: ZoomAnimationContext,
        _ transitionAnimator: UIViewPropertyAnimator
    ) {
        let portal = context.portal

        // Dimming in, presenter pushed back, status bar. (Corner morph is added separately.)
        transitionAnimator.addAnimations {
            context.dimmingView?.alpha = 1
            context.presenterView?.transform = Self.presenterPushBack
            context.zoomedViewController.setNeedsStatusBarAppearanceUpdate()
        }

        // Placard fades out over the first 40% of the timeline.
        if let placard = portal.placardView {
            transitionAnimator.addAnimations {
                UIView.animateKeyframes(withDuration: 1, delay: 0, options: [.calculationModeLinear]) {
                    UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: Self.appearingPlacardFadeOutEnd) {
                        placard.alpha = 0
                    }
                }
            }
        }
    }

    // MARK: - Disappearing (dismiss)

    private func prepareDisappearing(
        _ context: ZoomAnimationContext,
        source: ResolvedSource,
        geometry: ZoomGeometry
    ) {
        let container = context.containerView
        let zoomedView = context.zoomedView
        let portal = context.portal

        // 2. Background: re-insert the presenter view under the departing view for `.fullScreen`.
        //    `.custom` keeps the presenter alive outside the container (nothing to do);
        //    `.overFullScreen` proceeds even with no `.to` view.
        if context.zoomedViewController.modalPresentationStyle == .fullScreen,
           let background = context.backgroundView {
            container.insertSubview(background, at: 0)
            background.frame = context.finalFrame
            container.layoutIfNeeded()
        }

        // 3. Portal at the live view's current (resting) frame; reparent identity.
        let currentFrame = zoomedView.frame
        container.addSubview(portal)
        portal.frame = currentFrame
        portal.portalCornerRadius = geometry.finalCornerRadius

        portal.contentContainer.addSubview(zoomedView)
        zoomedView.autoresizingMask = []
        zoomedView.frame = CGRect(origin: .zero, size: currentFrame.size)
        zoomedView.transform = .identity
        zoomedView.center = CGPoint(x: currentFrame.width / 2, y: currentFrame.height / 2)

        // Placard starts clear (fades in near the end), source hidden.
        if let placard = source.placard {
            placard.alpha = 0
            portal.placardView = placard
        }
        context.restorationToken.recordHide(of: source.view)
        source.view.isHidden = true

        // Dimming starts opaque; presenter push-back recorded so it can return to identity.
        context.dimmingView?.alpha = 1
        if let presenter = context.presenterView {
            context.restorationToken.recordTransform(of: presenter)
        }

        container.layoutIfNeeded()
    }

    private func configureDisappearingTransition(
        _ context: ZoomAnimationContext,
        _ transitionAnimator: UIViewPropertyAnimator
    ) {
        let portal = context.portal

        // Dimming out, presenter back to identity, status bar. (Corner morph is added separately.)
        transitionAnimator.addAnimations {
            context.dimmingView?.alpha = 0
            context.presenterView?.transform = .identity
            context.zoomedViewController.setNeedsStatusBarAppearanceUpdate()
        }

        // Placard fades in over the last 30% of the timeline.
        if let placard = portal.placardView {
            transitionAnimator.addAnimations {
                UIView.animateKeyframes(withDuration: 1, delay: 0, options: [.calculationModeLinear]) {
                    UIView.addKeyframe(
                        withRelativeStartTime: Self.disappearingPlacardFadeInStart,
                        relativeDuration: 1 - Self.disappearingPlacardFadeInStart
                    ) {
                        placard.alpha = 1
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Adds the corner-radius morph to the transition animator: to the container radius on the way
    /// in, back to the source radius on the way out. Split out of `makeTransitionAnimator` because
    /// the interactive path drives the corner directly from `cornerProgress` instead.
    private func addCornerMorph(to animator: UIViewPropertyAnimator, using context: ZoomAnimationContext) {
        guard let geometry = context.geometry else { return }
        let portal = context.portal
        let target = (context.phase == .appearing) ? geometry.finalCornerRadius : geometry.sourceCornerRadius
        animator.addAnimations {
            portal.portalCornerRadius = target
        }
    }

    /// Center that pins the top edge to y=0 and horizontally centers a `finalSize`-bounds view
    /// scaled by `scale` (derivation in the type doc / report).
    private func scaledTopCenter(finalSize: CGSize, scale: CGFloat) -> CGPoint {
        CGPoint(x: finalSize.width * scale / 2, y: finalSize.height * scale / 2)
    }

    private func makeSpringAnimator(_ spring: ZoomTransition.Spring) -> UIViewPropertyAnimator {
        let timing = SpringConverter.timingParameters(
            response: spring.response,
            dampingRatio: spring.dampingRatio
        )
        return UIViewPropertyAnimator(duration: spring.response, timingParameters: timing)
    }
}
