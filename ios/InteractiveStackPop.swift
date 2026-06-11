import Foundation
import QuartzCore
import UIKit

/// Drives an INTERACTIVE shared-hero return for the iOS left-edge swipe-back
/// pop (`UINavigationController.interactivePopGestureRecognizer`, enabled by
/// default under `react-native-screens`).
///
/// ## Why a dedicated controller
///
/// The registry's normal back-flight is queued from `commitUnregister`, which
/// React-Navigation only runs once the pop COMPLETES. A flight starting then
/// can't track the finger, and on a normal-speed swipe the re-entering list is
/// still parallax-sliding — so it lands on a moving target (the reported "flies
/// to the wrong spot, veers left, then corrects"). A fast swipe only hides this
/// because the slide is already done by the time that late flight fires.
///
/// RNS owns the navigation controller, so we can't hook the transition.
/// Instead we OBSERVE the real motion (only ever via `windowFrame()`) and drive
/// our own overlay — like `InteractiveModalReturn`, but horizontal and tracking
/// a LIVE destination:
///   * Armed at push time on the pushed `detail` (destination = list `twin`);
///     stands down if the detail isn't in a popable nav controller.
///   * `translation = live.minX - natural.minX` = how far the screen dragged.
///   * On a rightward drag, hide the real detail + list cell and add an overlay
///     that lerps from the finger-following source to the list cell's LIVE
///     (also-sliding) frame, keeping overlay and list locked — no veer.
///   * On commit, keep the overlay glued to that live frame until the slide
///     settles, THEN crossfade to the real hero (revealing earlier is the
///     "still-sliding hero" glitch). On cancel, restore. Commit vs cancel is
///     UIKit's decision; we just follow it.
///
/// ## Multiple heroes per pop
///
/// One popping screen can carry several heroes (e.g. MultiStep's first detail:
/// a big hero AND an "Up next" thumbnail). Each fires its own `runTwinFlight`,
/// so we track a SET of `TrackedPair`s and advance/finish them together, using
/// one armed `detail` as the "driver" for drag/settle/release sampling.
/// Adopting every pair also stops a secondary from falling through to the
/// registry's time-driven flight, whose trailing re-`arm()` would tear down
/// this session.
@objc public final class InteractiveStackPop: NSObject {
  @objc public static let shared = InteractiveStackPop()
  private override init() { super.init() }

  // MARK: - Tunables.

  /// Frames of <0.5pt horizontal change before the push counts as settled
  /// (and we capture the natural resting frame).
  private static let settleStableFrames = 3
  /// Rightward drag (pt) that arms the overlay. Small for near-instant
  /// tracking, non-zero so jitter / a non-sliding button-pop fade can't trip it.
  private static let activateThreshold: CGFloat = 6
  /// Translation at/below which an active drag counts as cancelled (back at rest).
  private static let cancelThreshold: CGFloat = 2
  /// Tolerance (pt) between the list cell's live and settled frames that marks
  /// the parallax slide as finished.
  private static let settleTolerance: CGFloat = 1.5
  /// Ceiling on the post-commit settle wait, so a dest that never settles
  /// (torn down / relaid-out) is still revealed.
  private static let maxCommitSettleSeconds: CFTimeInterval = 1.0

  // MARK: - Tracked pair.

  /// One (detail hero → re-entering list twin) pair in the current pop. A
  /// reference type so an animation-completion closure can clear its own
  /// `overlay`. All pairs advance and finish together.
  private final class TrackedPair {
    weak var detail: SharedHeroViewImpl?
    weak var twin: SharedHeroViewImpl?
    /// Clean detail snapshot from the registry at adopt time (captured fully
    /// on-screen) — used as the overlay bitmap instead of re-capturing mid-slide.
    let snap: HeroSnapshot
    /// Detail's natural resting frame: the overlay's start, and its cancel target.
    var sourceRect: CGRect
    var overlay: UIView?
    var sourceCorner: CGFloat = 0
    var destCorner: CGFloat = 0

    init(detail: SharedHeroViewImpl, twin: SharedHeroViewImpl, snap: HeroSnapshot, sourceRect: CGRect) {
      self.detail = detail
      self.twin = twin
      self.snap = snap
      self.sourceRect = sourceRect
    }
  }

  // MARK: - Session state.

  /// The armed "driver" hero: its motion drives drag detection, natural-rect /
  /// settle sampling, and the transition coordinator we sync to. All adopted
  /// pairs are on the same popping screen and slide with it, so one suffices.
  private weak var detail: SharedHeroViewImpl?

  /// Every adopted (detail, twin) pair, including the driver's. Secondary
  /// heroes are appended as their twin flights fire.
  private var pairs: [TrackedPair] = []

  private var link: CADisplayLink?
  /// Push has settled and `naturalRect` is valid.
  private var ready = false
  /// A rightward drag is in progress and the overlays are live.
  private var active = false
  /// Pop committed via the FALLBACK path (no transition coordinator): holding
  /// the overlays on the list cells until their parallax slide finishes.
  private var committing = false
  /// Finger released; running the overlay animation SYNCED to UIKit's
  /// finish/cancel. While true the display link stands down — `windowFrame()`
  /// has jumped to the model's final value and is useless for tracking.
  private var finishing = false
  /// Outstanding per-pair finish animations; shared teardown runs at zero.
  private var finishRemaining = 0

  /// Overlay host retained once per session and shared by all overlays, so the
  /// `OverlayHost` ref-count stays balanced (one `host()` ↔ one `releaseHost()`).
  private var hostView: UIView?
  private var hostRetained = false

  /// The driver's natural resting frame (push settled); drag is measured from it.
  private var naturalRect: CGRect = .zero
  private var dismissRef: CGFloat = 1

  private var lastX: CGFloat = .greatestFiniteMagnitude
  private var stableFrames = 0
  private var commitDeadline: CFTimeInterval = 0

  /// Set once `tryAdoptInteractivePop` confirms a real edge-swipe pop and
  /// suppresses the registry's flight for ≥1 pair. We only `activate()` when
  /// adopted, so a missed detection stays dormant instead of stacking a second
  /// competing overlay on top of the registry's flight.
  private var adopted = false

  /// The hero has attached to a window at least once. Before that, a
  /// `window == nil` reading just means the push is still animating in.
  private var everAttached = false
  private var attachDeadline: CFTimeInterval = 0
  private static let maxAttachWaitSeconds: CFTimeInterval = 8

  // MARK: - Arming (called from HeroRegistry.runTwinFlight).

  /// Arm pop tracking for a pushed `detail` whose return destination is `twin`.
  /// Called for every twin flight on the forward push; the last call wins. Fine
  /// — the driver only needs to be SOME hero on the popping screen, and on the
  /// back swipe every pair is adopted via `tryAdoptInteractivePop`.
  func arm(detail: SharedHeroViewImpl, twin: SharedHeroViewImpl) {
    disarm()
    self.detail = detail
    self.ready = false
    self.active = false
    self.committing = false
    self.finishing = false
    self.adopted = false
    self.pairs = []
    self.lastX = .greatestFiniteMagnitude
    self.stableFrames = 0
    self.everAttached = false
    self.attachDeadline = CACurrentMediaTime() + Self.maxAttachWaitSeconds
    startLink()
  }

  /// Called from `HeroRegistry.runTwinFlight` for each back-transition twin
  /// flight. When the nav controller reports an INTERACTIVE transition (the
  /// edge-swipe, not a push or button pop) and this hero shares the driver's
  /// window, adopt the pair (stash its clean snapshot + re-entering `dest` twin)
  /// and return `true` so the registry skips its time-driven flight and the
  /// trailing re-`arm()` that would tear down this session.
  ///
  /// Returns `false` for a push, button pop, non-popable context, or before the
  /// driver has settled — leaving the registry's normal flight intact.
  func tryAdoptInteractivePop(
    detail: SharedHeroViewImpl,
    dest: SharedHeroViewImpl,
    sourceSnap: HeroSnapshot
  ) -> Bool {
    guard ready, !committing, !finishing else { return false }
    guard let driver = self.detail else { return false }
    guard Self.isInteractivePopInProgress(driver.contentView) else { return false }
    // Must be on the SAME popping screen as the driver: they slide together
    // under one gesture and share a window. An unrelated screen does not, and is
    // left to the registry's normal flight.
    guard detail.contentView.window === driver.contentView.window else { return false }
    // Idempotent: re-triggering an already-tracked detail is a no-op, but still
    // "handled" so the caller skips its time-driven flight.
    if pairs.contains(where: { $0.detail === detail }) { return true }

    // Driver's resting frame was sampled live at settle; a secondary's comes
    // from the snapshot's transform-free settled frame.
    let sourceRect: CGRect = (detail === driver)
      ? naturalRect
      : (nonZero(sourceSnap.settledFrame) ?? nonZero(sourceSnap.frame) ?? detail.windowFrame())
    let pair = TrackedPair(detail: detail, twin: dest, snap: sourceSnap, sourceRect: sourceRect)
    pairs.append(pair)
    adopted = true

    // Suppress the list hero's own unregister-twin back-flight. On a CANCEL (or
    // too-short swipe) the list screen slides back off and that hero unregisters
    // while detail is still its live twin, which would fire a spurious
    // list→detail flight after the detail already snapped back ("image flies one
    // more time"). The mark makes its `commitUnregister` early-return; on a real
    // pop the list stays on-window, so the mark is just cleared later.
    HeroRegistry.shared.markInteractivelyHandled(dest)
    // Hide the list cell NOW (synchronously, as it re-attaches), not at
    // `activate()`: otherwise its image is visible during the few-pixel gap
    // before the activation threshold and flashes on then blanks. Restored on
    // cancel/gesture-end (`restoreTwins`/`disarm`), handed off on commit.
    dest.setHiddenForFlight(true)

    // Late adopt while already tracking (a secondary's flight a tick after
    // activation): build its overlay now so it joins the others.
    if active {
      buildOverlay(for: pair)
    }

    heroLog(HeroLog.stackPop, "adopt interactive pop detail=\(ObjectIdentifier(detail)) dest=\(ObjectIdentifier(dest)) pairs=\(pairs.count) active=\(active)")
    return true
  }

  // MARK: - Display link.

  private func startLink() {
    stopLink()
    let l = CADisplayLink(target: self, selector: #selector(tick))
    l.add(to: .main, forMode: .common)
    link = l
  }

  private func stopLink() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick() {
    // Synced finish owns everything now; don't let the link fight it (the model
    // frame has jumped to its final value).
    if finishing {
      return
    }

    // Post-commit FALLBACK (no coordinator): hold the overlays on the list
    // cells until their slide finishes, then hand off. Runs even off-window.
    if committing {
      driveCommit()
      return
    }

    guard let detail = detail else { disarm(); return }

    // Off-window: before first attach the push is still animating in (wait,
    // bounded); after having attached, the pop completed.
    guard detail.contentView.window != nil else {
      if everAttached {
        if active {
          beginCommit()
        } else {
          // Non-interactive pop (button / fade) — let the registry's normal
          // back-flight handle it.
          disarm()
        }
      } else if CACurrentMediaTime() > attachDeadline {
        disarm()
      }
      return
    }
    everAttached = true

    let live = detail.windowFrame()
    guard live != .zero else { return }

    if !ready {
      // Sample the natural resting frame once the push settles, i.e. once the
      // horizontal position stops moving.
      if abs(live.minX - lastX) < 0.5 {
        stableFrames += 1
        if stableFrames >= Self.settleStableFrames {
          if Self.isInteractivePopContext(detail.contentView) {
            naturalRect = live
            let screenW = detail.contentView.window?.bounds.width ?? UIScreen.main.bounds.width
            dismissRef = max(1, screenW)
            ready = true
          } else {
            // Not a popable native-stack screen (sheet/modal handled by
            // InteractiveModalReturn, or a fullscreen presentation).
            disarm()
          }
        }
      } else {
        stableFrames = 0
      }
      lastX = live.minX
      return
    }

    let tc = Self.navTransitionCoordinator(detail.contentView)

    // RELEASE DETECTION. On finger-lift the transition stops being interactive:
    // UIKit snaps the layer's MODEL value to its final state and animates only
    // the presentation layer. `windowFrame()` is model-based, so it has jumped
    // to the end — stop finger-tracking and run the overlay SYNCED to UIKit's
    // completion (same duration + curve) so the heroes land with the page slide
    // (commit) or return to rest (cancel) instead of snapping.
    if active, let tc = tc, !tc.isInteractive {
      beginSyncedFinish(
        cancelled: tc.isCancelled,
        duration: tc.transitionDuration,
        curve: tc.completionCurve
      )
      return
    }

    let translation = live.minX - naturalRect.minX

    if !active {
      // Finger lifted BEFORE crossing the activation threshold — a swipe so
      // short or so FAST that `tick()` never saw the drag cross it, so no
      // overlays were built. UIKit has already decided, so branch on what it
      // actually did rather than assuming a cancel:
      if adopted, let tc = tc, !tc.isInteractive {
        if tc.isCancelled {
          // CANCEL: restore the list cells hidden at adopt time, stay
          // armed/ready for the next swipe. No flight — the detail never left.
          heroLog(HeroLog.stackPop, "gesture cancelled before activation — restoring twins")
          restoreTwins()
          return
        }
        // COMMIT (fast swipe that popped for real): never tracked the finger,
        // but the detail IS leaving. Synthesize overlays and run the same synced
        // commit. Keeping the return in-controller (details stay marked) means
        // their unregister won't fire the registry's late, mis-positioned flight.
        heroLog(HeroLog.stackPop, "gesture committed before activation — synthesizing commit")
        synthesizeOverlaysForCommit()
        beginSyncedFinish(
          cancelled: false,
          duration: tc.transitionDuration,
          curve: tc.completionCurve
        )
        return
      }
      // A pop is a RIGHTWARD drag, and only once `adopted` (registry confirmed
      // the interactive pop and suppressed its own flight). The gate stops a
      // missed detection from stacking our overlay on the registry's flight; a
      // button-pop fade doesn't move in x, so it never trips this anyway.
      if adopted && translation > Self.activateThreshold {
        activate()
      }
      return
    }

    // FALLBACK cancel detection when there's no coordinator to sync to —
    // just restore at rest.
    if tc == nil, translation <= Self.cancelThreshold {
      finalizeCancel()
      return
    }

    let p = max(0, min(1, translation / dismissRef))
    driveOverlays(translation: translation, progress: p)
  }

  // MARK: - Interactive overlay lifecycle.

  private func activate() {
    guard !pairs.isEmpty else { return }
    for pair in pairs {
      buildOverlay(for: pair)
    }
    active = true
    heroLog(HeroLog.stackPop, "activate pairs=\(pairs.count) natural=\(naturalRect) dismissRef=\(dismissRef)")
  }

  /// Build one pair's overlay from its clean snapshot, hide both real heroes,
  /// and claim the transition from the registry. Shared by `activate()` and the
  /// fast-commit synthesis path.
  private func buildOverlay(for pair: TrackedPair) {
    guard let detail = pair.detail else { return }
    if pair.overlay != nil { return }

    // Prefer the registry's clean adopt-time snapshot; fall back to live capture.
    let image = pair.snap.image ?? detail.captureSnapshot()?.image

    pair.sourceCorner = detail.effectiveCornerRadius()
    pair.destCorner = pair.twin?.effectiveCornerRadius() ?? pair.sourceCorner

    let ov = UIView(frame: pair.sourceRect)
    ov.backgroundColor = .clear
    ov.clipsToBounds = true
    ov.layer.cornerRadius = pair.sourceCorner
    ov.layer.masksToBounds = true
    if let img = image {
      let iv = UIImageView(image: img)
      iv.frame = ov.bounds
      iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      iv.contentMode = .scaleAspectFill
      ov.addSubview(iv)
    }

    overlayHostView().addSubview(ov)
    pair.overlay = ov

    detail.setHiddenForFlight(true)
    pair.twin?.setHiddenForFlight(true)
    detail.emitTransitionStart()
    // We own this pair now, so the registry's unregister back-flight must stand
    // down (mirrors its `alreadyFlighted` source-flight guard).
    HeroRegistry.shared.markInteractivelyHandled(detail)
  }

  /// Build overlays for a COMMIT that beat the activation threshold (a very fast
  /// swipe). With no finger tracking, each overlay starts at its detail's
  /// natural resting frame (where the snapshot was taken) rather than
  /// `windowFrame()`, whose model value may already have jumped off-screen. The
  /// caller then runs `beginSyncedFinish(cancelled: false)`.
  private func synthesizeOverlaysForCommit() {
    for pair in pairs {
      buildOverlay(for: pair)
    }
    heroLog(HeroLog.stackPop, "synthesizeOverlaysForCommit pairs=\(pairs.count)")
  }

  private func driveOverlays(translation: CGFloat, progress p: CGFloat) {
    for pair in pairs {
      guard let ov = pair.overlay else { continue }
      // Source follows the finger (detail slides right by `translation`).
      // Destination is the LIVE list cell, itself parallax-sliding in, so read
      // its frame EVERY frame instead of pinning a stale rect. The lerp keeps
      // the overlay locked between the two moving anchors.
      let followed = pair.sourceRect.offsetBy(dx: translation, dy: 0)
      let dest = liveDestRect(pair) ?? followed
      ov.frame = Self.lerpRect(followed, dest, p)
      ov.layer.cornerRadius = pair.sourceCorner + (pair.destCorner - pair.sourceCorner) * p
    }
  }

  /// Begin the post-commit handoff: the detail left the window, so keep the link
  /// running to drive the overlays onto the list cells' live frames until the
  /// slide settles.
  private func beginCommit() {
    committing = true
    active = false
    commitDeadline = CACurrentMediaTime() + Self.maxCommitSettleSeconds
    heroLog(HeroLog.stackPop, "beginCommit pairs=\(pairs.count)")
  }

  private func driveCommit() {
    guard !pairs.isEmpty else { finishCommit(); return }
    var allConverged = true
    let tol = Self.settleTolerance
    for pair in pairs {
      guard let ov = pair.overlay else { continue }
      guard let twin = pair.twin, twin.contentView.window != nil else {
        // Dest gone/off-window — nothing to glue to; treat as converged.
        continue
      }
      let live = twin.windowFrame()
      let settled = twin.settledWindowFrame()
      if live != .zero {
        // Glue the overlay onto the still-sliding cell so they move as one; when
        // the slide finishes (live ≈ settled) the crossfade lands with the real
        // hero exactly under the overlay — zero jump.
        ov.frame = live
        ov.layer.cornerRadius = pair.destCorner
      }
      let converged = live != .zero
        && abs(live.origin.x - settled.origin.x) < tol
        && abs(live.origin.y - settled.origin.y) < tol
        && abs(live.width - settled.width) < tol
        && abs(live.height - settled.height) < tol
      if !converged { allConverged = false }
    }
    if allConverged || CACurrentMediaTime() > commitDeadline {
      finishCommit()
    }
  }

  private func finishCommit() {
    heroLog(HeroLog.stackPop, "finishCommit pairs=\(pairs.count)")
    for pair in pairs {
      pair.twin?.setHiddenForFlight(false)
      if let ov = pair.overlay {
        UIView.animate(
          withDuration: 0.12,
          animations: { ov.alpha = 0 },
          completion: { _ in
            ov.removeFromSuperview()
            pair.overlay = nil
          }
        )
      }
      pair.detail?.emitTransitionEnd()
    }
    releaseHostIfNeeded()
    // Do NOT `unmarkInteractivelyHandled`: the details are being torn down and
    // their deferred `commitUnregister` must keep early-returning so they don't
    // fire redundant back-flights. `register` clears the stale marks on remount.
    self.detail = nil
    self.pairs = []
    self.active = false
    self.committing = false
    self.ready = false
    self.adopted = false
    stopLink()
  }

  /// Animate the overlays in lock-step with UIKit's finish/cancel completion
  /// after release. `duration`/`curve` come from the nav controller's transition
  /// coordinator so we match the page slide. All pairs animate together; shared
  /// teardown runs after the last one completes.
  private func beginSyncedFinish(
    cancelled: Bool,
    duration: TimeInterval,
    curve: UIView.AnimationCurve
  ) {
    let live = pairs.filter { $0.overlay != nil && $0.detail != nil }
    guard !live.isEmpty else { disarm(); return }
    finishing = true
    active = false
    finishRemaining = live.count
    let dur = duration > 0.05 ? duration : 0.3
    let opt = Self.animationOption(for: curve)

    if cancelled {
      heroLog(HeroLog.stackPop, "syncedCancel dur=\(dur) pairs=\(live.count)")
      // Fly each overlay back to its detail's resting position as the page
      // slides back. Keep BOTH real heroes hidden throughout: the list cell is
      // sliding back off behind the returning detail, and un-hiding it early is
      // the "main hero flashes on the lower layer" glitch.
      for pair in live {
        guard let ov = pair.overlay, let detail = pair.detail else { onFinishPairDone(cancelled: true); continue }
        UIView.animate(
          withDuration: dur,
          delay: 0,
          options: [opt, .allowUserInteraction],
          animations: {
            ov.frame = pair.sourceRect
            ov.layer.cornerRadius = pair.sourceCorner
          },
          completion: { _ in
            detail.setHiddenForFlight(false)
            pair.twin?.setHiddenForFlight(false)
            ov.removeFromSuperview()
            pair.overlay = nil
            HeroRegistry.shared.unmarkInteractivelyHandled(detail)
            detail.emitTransitionEnd()
            self.onFinishPairDone(cancelled: true)
          }
        )
      }
    } else {
      // Commit: the model frame has jumped to its settled state, so
      // `twin.windowFrame()` now reports each list cell's final rest position.
      // Fly each overlay there over the same duration/curve as the page slide,
      // then crossfade to the real (now-settled) cell.
      for pair in live {
        guard let ov = pair.overlay, let detail = pair.detail else { onFinishPairDone(cancelled: false); continue }
        let finalRect = nonZero(pair.twin?.windowFrame())
          ?? nonZero(pair.twin?.settledWindowFrame())
          ?? ov.frame
        heroLog(HeroLog.stackPop, "syncedCommit dur=\(dur) final=\(finalRect)")
        let twin = pair.twin
        UIView.animate(
          withDuration: dur,
          delay: 0,
          options: [opt, .allowUserInteraction],
          animations: {
            ov.frame = finalRect
            ov.layer.cornerRadius = pair.destCorner
          },
          completion: { _ in
            twin?.setHiddenForFlight(false)
            UIView.animate(
              withDuration: 0.1,
              animations: { ov.alpha = 0 },
              completion: { _ in
                ov.removeFromSuperview()
                pair.overlay = nil
                self.onFinishPairDone(cancelled: false)
              }
            )
            detail.emitTransitionEnd()
          }
        )
      }
    }
  }

  /// Per-pair finish completion; the shared teardown runs once all pairs finish
  /// so the host is released exactly once.
  private func onFinishPairDone(cancelled: Bool) {
    finishRemaining -= 1
    guard finishRemaining <= 0 else { return }
    releaseHostIfNeeded()
    finishing = false
    pairs = []
    active = false
    adopted = false
    if cancelled {
      // Detail never left — stay armed + ready so the next swipe re-adopts.
    } else {
      // Details are being torn down; keep them marked so their deferred
      // `commitUnregister` stays suppressed (no redundant back-flight).
      detail = nil
      ready = false
      stopLink()
    }
  }

  private func finalizeCancel() {
    heroLog(HeroLog.stackPop, "finalizeCancel pairs=\(pairs.count)")
    // Screen is back at rest, so each real hero is already at its `sourceRect`
    // and the overlay (progress ≈ 0) sits on top — un-hide and remove, no jump.
    for pair in pairs {
      pair.detail?.setHiddenForFlight(false)
      pair.twin?.setHiddenForFlight(false)
      pair.overlay?.removeFromSuperview()
      pair.overlay = nil
      pair.detail.map { HeroRegistry.shared.unmarkInteractivelyHandled($0) }
      pair.detail?.emitTransitionEnd()
    }
    releaseHostIfNeeded()
    active = false
    adopted = false
    pairs = []
    // Stay armed + ready so a subsequent drag re-triggers.
  }

  // MARK: - Overlay host ref-counting.

  /// The shared overlay host, retained once per session (on the first overlay)
  /// and cached so later overlays reuse it without bumping the host count.
  private func overlayHostView() -> UIView {
    if let h = hostView { return h }
    let h = OverlayHost.shared.host()
    hostView = h
    hostRetained = true
    return h
  }

  private func releaseHostIfNeeded() {
    if hostRetained {
      OverlayHost.shared.releaseHost()
      hostRetained = false
    }
    hostView = nil
  }

  /// Un-hide the list cells hidden at adopt time, for an adopted gesture that
  /// ends without ever activating (a tiny swipe). Deliberately does NOT
  /// `unmarkInteractivelyHandled(twin)`: if the list slides back off it
  /// unregisters, and that mark keeps its `commitUnregister` quiet (consumed
  /// there). Clears the pairs so the next swipe re-adopts cleanly.
  private func restoreTwins() {
    for pair in pairs {
      pair.twin?.setHiddenForFlight(false)
    }
    pairs = []
    adopted = false
  }

  /// Tear the session down immediately without reversing or completing a
  /// transition. Used when arming a new session or when the hero is no longer
  /// eligible (deallocated, not a popable screen, non-interactive pop).
  private func disarm() {
    stopLink()
    for pair in pairs {
      if active {
        pair.detail?.setHiddenForFlight(false)
        pair.detail.map { HeroRegistry.shared.unmarkInteractivelyHandled($0) }
      }
      // List cells are hidden from adopt time (before `activate`), so restore
      // on ANY teardown where we'd adopted, not just when active.
      if adopted {
        pair.twin?.setHiddenForFlight(false)
      }
      pair.overlay?.removeFromSuperview()
      pair.overlay = nil
    }
    releaseHostIfNeeded()
    pairs = []
    detail = nil
    ready = false
    active = false
    committing = false
    finishing = false
    adopted = false
  }

  // MARK: - Helpers.

  /// The list cell's LIVE (parallax-sliding) window rect, or nil if unusable.
  private func liveDestRect(_ pair: TrackedPair) -> CGRect? {
    guard let twin = pair.twin, twin.contentView.window != nil else { return nil }
    let f = twin.windowFrame()
    return f != .zero ? f : nil
  }

  /// True if `view` is in a `UINavigationController` with something to pop and
  /// not inside a swipe-dismissable sheet (those belong to `InteractiveModalReturn`).
  private static func isInteractivePopContext(_ view: UIView) -> Bool {
    if InteractiveModalReturn.isInSheet(view) { return false }
    var responder: UIResponder? = view
    while let r = responder {
      if let nav = r as? UINavigationController, nav.viewControllers.count > 1 {
        return true
      }
      responder = r.next
    }
    return false
  }

  /// True if `view`'s host `UINavigationController` is running an INTERACTIVE
  /// transition (the user-driven edge-swipe), not a programmatic push or button
  /// pop. This is what distinguishes the gesture we track from every other
  /// twin-flight flowing through `runTwinFlight`.
  private static func isInteractivePopInProgress(_ view: UIView) -> Bool {
    var responder: UIResponder? = view
    while let r = responder {
      if let nav = r as? UINavigationController {
        guard let tc = nav.transitionCoordinator else { return false }
        return tc.isInteractive || tc.initiallyInteractive
      }
      responder = r.next
    }
    return false
  }

  /// The host `UINavigationController`'s active transition coordinator — used to
  /// detect release and match the finish/cancel duration + curve.
  private static func navTransitionCoordinator(_ view: UIView) -> UIViewControllerTransitionCoordinator? {
    var responder: UIResponder? = view
    while let r = responder {
      if let nav = r as? UINavigationController { return nav.transitionCoordinator }
      responder = r.next
    }
    return nil
  }

  private static func animationOption(for curve: UIView.AnimationCurve) -> UIView.AnimationOptions {
    switch curve {
    case .easeIn: return .curveEaseIn
    case .easeOut: return .curveEaseOut
    case .easeInOut: return .curveEaseInOut
    case .linear: return .curveLinear
    @unknown default: return .curveEaseOut
    }
  }

  private func nonZero(_ rect: CGRect?) -> CGRect? {
    guard let rect = rect, rect != .zero else { return nil }
    return rect
  }

  private static func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(
      x: a.origin.x + (b.origin.x - a.origin.x) * t,
      y: a.origin.y + (b.origin.y - a.origin.y) * t,
      width: a.size.width + (b.size.width - a.size.width) * t,
      height: a.size.height + (b.size.height - a.size.height) * t
    )
  }
}
