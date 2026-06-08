import Foundation
import QuartzCore
import UIKit

/// Drives an INTERACTIVE shared-hero return when a native-stack screen is
/// popped by the iOS left-edge swipe-back gesture (the
/// `interactivePopGestureRecognizer` that `UINavigationController` /
/// `react-native-screens` enables by default).
///
/// ## Why this exists (and why the time-driven back-flight could not fix it)
///
/// The registry's normal back-flight for a pop is queued from
/// `commitUnregister` — i.e. only when the detail screen is *unmounted*, which
/// React-Navigation does at the END of the pop. By then the gesture is over,
/// so a fixed-duration flight that starts at that moment can never track the
/// finger. Worse, on a normal-speed swipe the underlying (re-entering) LIST
/// screen is still parallax-sliding left→right when the flight fires, so the
/// landing target is a moving goalpost — the reported "detail flies to the
/// wrong position, veers left, then corrects". A very FAST swipe hides this
/// only because the slide is already finished by the time the late flight
/// fires.
///
/// We cannot hook UIKit's interactive pop transition (RNS owns the navigation
/// controller), so instead we OBSERVE the real motion and drive our own overlay
/// copy — the same strategy as `InteractiveModalReturn`, but on the horizontal
/// axis and, crucially, tracking a LIVE destination:
///
///   * Armed at push time on the freshly-pushed `detail` hero (return
///     destination = `twin`, the list hero). Cheap for non-pop flights: if the
///     detail is not inside a popable nav controller (e.g. a sheet/modal, which
///     `InteractiveModalReturn` owns) we stand down once it settles on-window.
///   * `translation = live.minX - natural.minX` is exactly how far the detail
///     screen has been dragged right (works whether UIKit drives it by frame or
///     transform — we only ever read `windowFrame()`).
///   * Once a rightward drag is detected we hide the real detail hero + the list
///     thumbnail and add an overlay snapshot. Each frame we move the overlay
///     from the finger-following source toward the list thumbnail's LIVE window
///     position (which is itself parallax-sliding in), so the overlay and the
///     real re-entering list stay locked together — no veer.
///   * When the detail leaves the window (pop committed) we keep the overlay
///     glued to the list thumbnail's live frame until the parallax slide
///     actually finishes, THEN crossfade to the real hero. Revealing only after
///     the slide settles is what removes the "reveal a still-sliding hero"
///     glitch entirely. If the detail returns to rest (drag cancelled) we
///     restore the heroes. The commit/cancel decision is UIKit's — we just
///     follow whatever the navigation controller actually does.
///
/// ## Multiple heroes per pop
///
/// A single popping screen can carry MORE than one shared hero across the same
/// interactive transition (e.g. the MultiStep example's first detail shows a
/// big hero AND an "Up next" thumbnail, both of which match a twin on the
/// re-entering list). Each twin pair fires its own `runTwinFlight`, so the
/// controller must adopt and drive ALL of them, not just the one it armed on.
/// We therefore track a SET of `TrackedPair`s — each with its own overlay,
/// source snapshot and source/dest frames — but use a single armed `detail`
/// (the "driver") to observe the drag, detect settle/release and read the
/// transition coordinator. Every overlay advances on the same `tick()` using
/// the same progress and finishes together in the release/commit path. Without
/// this, the un-adopted secondary pair fell through to the registry's
/// time-driven flight (which fires at the parallax mid-slide position, ignoring
/// the finger) AND its fall-through re-`arm()` tore down the driver's session,
/// so even the adopted hero degraded.
@objc public final class InteractiveStackPop: NSObject {
  @objc public static let shared = InteractiveStackPop()
  private override init() { super.init() }

  // MARK: - Tunables.

  /// Frames of <0.5pt horizontal change before we treat the push animation as
  /// settled and capture the hero's natural resting frame.
  private static let settleStableFrames = 3
  /// Rightward translation (points) that arms the interactive overlay. Small so
  /// the hero starts tracking almost immediately, but non-zero so layout jitter
  /// / a button-pop fade (which does not slide horizontally) doesn't trigger it.
  private static let activateThreshold: CGFloat = 6
  /// Translation at/below which an active drag is considered cancelled (the
  /// screen slid back to rest).
  private static let cancelThreshold: CGFloat = 2
  /// Convergence tolerance (points) between the list thumbnail's live and
  /// settled window frames used to detect "parallax slide finished".
  private static let settleTolerance: CGFloat = 1.5
  /// Wall-clock ceiling on the post-commit settle wait, so a destination that
  /// never settles (torn down / relaid-out) is still revealed.
  private static let maxCommitSettleSeconds: CFTimeInterval = 1.0

  // MARK: - Tracked pair.

  /// One (detail hero → re-entering list twin) pair adopted for the current
  /// interactive pop. Reference type so a pair captured in an animation
  /// completion can clear its own `overlay` after teardown. All pairs are
  /// advanced together by `tick()` and finished together in the synced
  /// finish / commit path.
  private final class TrackedPair {
    weak var detail: SharedHeroViewImpl?
    weak var twin: SharedHeroViewImpl?
    /// The clean source (detail) snapshot handed over by the registry at
    /// adopt time (captured while the detail was fully on-screen), used as
    /// the overlay bitmap instead of re-capturing mid-slide.
    let snap: HeroSnapshot
    /// The detail hero's natural resting window frame — where the overlay
    /// starts and where it returns to on cancel.
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

  /// The armed hero whose motion drives the whole session — drag detection,
  /// natural-rect / settle sampling, and the transition coordinator we sync
  /// the finish to. All adopted pairs slide together with this hero (they are
  /// on the same popping screen), so one driver suffices.
  private weak var detail: SharedHeroViewImpl?

  /// Every (detail, twin) pair adopted for the current interactive pop. The
  /// driver's own pair is included; secondary heroes are appended as their
  /// twin flights fire.
  private var pairs: [TrackedPair] = []

  private var link: CADisplayLink?
  /// Push animation has settled and `naturalRect` is valid.
  private var ready = false
  /// A rightward drag is in progress and the overlays are live.
  private var active = false
  /// The pop committed (detail left the window) via the FALLBACK path (no
  /// transition coordinator to observe); we're holding the overlays on the
  /// list thumbnails until their parallax slide finishes.
  private var committing = false
  /// The user released their finger and we're running our overlay animation
  /// SYNCED to UIKit's finish/cancel completion. While true, the display link
  /// stops driving the overlays (`windowFrame()` has jumped to the model's
  /// final value, so it can no longer be used for tracking).
  private var finishing = false
  /// Outstanding per-pair finish animations; the shared teardown (host
  /// release, state reset) runs once this reaches zero.
  private var finishRemaining = 0

  /// The library overlay host view, retained once per session and shared by
  /// every pair's overlay so the `OverlayHost` ref-count stays balanced
  /// (one `host()` ↔ one `releaseHost()`) no matter how many overlays exist.
  private var hostView: UIView?
  private var hostRetained = false

  /// The DRIVER's natural resting window frame (push settled). Drag
  /// translation is measured against this.
  private var naturalRect: CGRect = .zero
  private var dismissRef: CGFloat = 1

  private var lastX: CGFloat = .greatestFiniteMagnitude
  private var stableFrames = 0
  private var commitDeadline: CFTimeInterval = 0

  /// Set by `tryAdoptInteractivePop` once the registry has confirmed this is a
  /// real interactive edge-swipe pop and SUPPRESSED its own time-driven
  /// flight for at least one pair. We only `activate()` the overlays when
  /// adopted — so if the interactive detection ever misses (and the registry
  /// fired its normal flight instead), we stay dormant rather than stacking a
  /// second competing overlay.
  private var adopted = false

  /// The tracked hero has attached to a window at least once. Until then a
  /// `window == nil` reading just means the push is still animating in.
  private var everAttached = false
  private var attachDeadline: CFTimeInterval = 0
  private static let maxAttachWaitSeconds: CFTimeInterval = 8

  // MARK: - Arming (called from HeroRegistry.runTwinFlight).

  /// Arm interactive pop tracking for a freshly-pushed `detail` hero whose
  /// return destination is `twin` (the source/list hero). `arm` is called for
  /// every twin flight on the forward push; the last call wins (a screen with
  /// multiple heroes arms several times). That is fine — the driver only needs
  /// to be SOME hero on the popping screen, and on the back swipe every twin
  /// pair (including the driver's) is adopted via `tryAdoptInteractivePop`.
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

  /// Called from `HeroRegistry.runTwinFlight` for EACH twin flight that fires
  /// during a back transition. If the host nav controller reports an
  /// INTERACTIVE transition in progress (the left-edge swipe-back gesture — as
  /// opposed to a programmatic push or a button pop) and this hero is on the
  /// same popping screen as our armed driver, adopt the pair: stash the clean
  /// source snapshot + the re-entering `dest` (list) twin, and return `true`
  /// so the registry SKIPS its time-driven flight (and its trailing re-`arm()`,
  /// which would otherwise tear down this very session). All adopted pairs are
  /// then driven together by the display link.
  ///
  /// Returns `false` for a forward push, a button pop, a non-popable context,
  /// or before the driver has settled — leaving the registry's normal flight
  /// intact.
  func tryAdoptInteractivePop(
    detail: SharedHeroViewImpl,
    dest: SharedHeroViewImpl,
    sourceSnap: HeroSnapshot
  ) -> Bool {
    guard ready, !committing, !finishing else { return false }
    guard let driver = self.detail else { return false }
    guard Self.isInteractivePopInProgress(driver.contentView) else { return false }
    // The adopting hero must live on the SAME popping screen as the driver.
    // Both detail heroes slide together under the same gesture, so they share
    // a window; a hero on an unrelated screen does not and is left to the
    // registry's normal flight.
    guard detail.contentView.window === driver.contentView.window else { return false }
    // Idempotent: a duplicate trigger for an already-tracked detail is a no-op
    // (but still "handled", so the caller doesn't fire a time-driven flight).
    if pairs.contains(where: { $0.detail === detail }) { return true }

    // The driver's resting frame was sampled live at settle; a secondary's
    // comes from the source snapshot's transform-free settled frame.
    let sourceRect: CGRect = (detail === driver)
      ? naturalRect
      : (nonZero(sourceSnap.settledFrame) ?? nonZero(sourceSnap.frame) ?? detail.windowFrame())
    let pair = TrackedPair(detail: detail, twin: dest, snap: sourceSnap, sourceRect: sourceRect)
    pairs.append(pair)
    adopted = true

    // Suppress the destination (list) hero's OWN unregister-twin back-flight.
    // The list hero re-registered to trigger this adopt; if the gesture is
    // CANCELLED (or is too short to commit) the list screen slides back off
    // and that hero unregisters while the detail is still the live twin —
    // which would otherwise fire a spurious, redundant list→detail back-flight
    // AFTER the detail has already snapped back (the reported "image flies one
    // more time"). Marking it interactively-handled makes its `commitUnregister`
    // take the early-return branch. On a successful pop the list stays
    // on-window (becomes the top screen) so the mark is simply consumed/cleared
    // later.
    HeroRegistry.shared.markInteractivelyHandled(dest)
    // Hide the list cell IMMEDIATELY (this runs synchronously as the list
    // re-attaches), not at `activate()`. Otherwise the real thumbnail is
    // visible for the few-pixel gap between swipe-start and the activation
    // threshold and the user sees its image flash on, then blank out when we
    // finally hide it. It's restored on cancel / gesture-end (see
    // `restoreTwins` / `disarm`) and handed off on commit.
    dest.setHiddenForFlight(true)

    // Late adopt while we're already tracking (a secondary's flight that fired
    // a tick after activation): build its overlay now so it joins the others.
    if active {
      buildOverlay(for: pair)
    }

    NSLog("[SharedHeroStackPop] adopt interactive pop detail=\(ObjectIdentifier(detail)) dest=\(ObjectIdentifier(dest)) pairs=\(pairs.count) active=\(active)")
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
    // Synced finish/cancel animation owns everything now — don't let the
    // display link fight it (the model frame has jumped to its final value).
    if finishing {
      return
    }

    // Post-commit FALLBACK (no transition coordinator): keep the overlays
    // locked onto the re-entering list thumbnails until their parallax slide
    // finishes, then hand off. Runs even after the detail has left the window.
    if committing {
      driveCommit()
      return
    }

    guard let detail = detail else { disarm(); return }

    // Hero off-window. Two cases:
    //   * Before first attach → push still animating in. Keep waiting (bounded).
    //   * After having been attached → the pop completed.
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
      // Wait for the push animation to settle before sampling a natural
      // resting frame. Detect settle as "horizontal position stopped moving".
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

    // RELEASE DETECTION. Once the user lifts their finger the transition stops
    // being interactive and UIKit/RNS animates the completion by snapping the
    // layer's MODEL value to its final state and animating only the
    // PRESENTATION layer. `windowFrame()` is model-based, so it has just jumped
    // to the end — we must stop finger-tracking and instead run our overlay
    // animation SYNCED to UIKit's completion (same duration + curve), so the
    // heroes land exactly as the page finishes sliding (commit) or return
    // smoothly to rest (cancel) instead of snapping.
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
      // Gesture ended (finger lifted) BEFORE we crossed the activation
      // threshold — i.e. a swipe so short, or so FAST, that `tick()` never
      // observed the drag cross `activateThreshold` and so never built the
      // overlays. UIKit has already decided the outcome (the transition is no
      // longer interactive), so branch on what it actually did rather than
      // assuming a cancel:
      if adopted, let tc = tc, !tc.isInteractive {
        if tc.isCancelled {
          // CANCEL (tiny swipe that snapped back to rest): restore the list
          // cells we hid at adopt time and reset adopt state, staying
          // armed/ready for the next swipe. No flight — the detail never left.
          NSLog("[SharedHeroStackPop] gesture cancelled before activation — restoring twins")
          restoreTwins()
          return
        }
        // COMMIT (a very fast swipe that popped for real): we never tracked the
        // finger, but the detail IS dismissing. Synthesize the overlays now
        // from the clean source snapshots and run the SAME synced commit flight
        // the slow path uses, flying each hero onto its list cell's settled
        // frame. Keeping the whole return inside the controller (the details
        // stay marked interactively-handled) means their unregister won't fire
        // the registry's late, mis-positioned back-flight.
        NSLog("[SharedHeroStackPop] gesture committed before activation — synthesizing commit")
        synthesizeOverlaysForCommit()
        beginSyncedFinish(
          cancelled: false,
          duration: tc.transitionDuration,
          curve: tc.completionCurve
        )
        return
      }
      // Only a RIGHTWARD drag is a pop, AND only once the registry has handed
      // this transition to us (`adopted`) — i.e. it confirmed an interactive
      // pop and suppressed its own flight. Without the `adopted` gate a missed
      // detection would leave us driving an overlay on top of the registry's
      // time-driven flight (two competing overlays). A push-fade screen does
      // not move in x, so a button pop never trips this regardless.
      if adopted && translation > Self.activateThreshold {
        activate()
      }
      return
    }

    // FALLBACK cancel detection only when there's no transition coordinator to
    // observe (we can't sync to UIKit, so just restore at rest).
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
    NSLog("[SharedHeroStackPop] activate pairs=\(pairs.count) natural=\(naturalRect) dismissRef=\(dismissRef)")
  }

  /// Build a single pair's flight overlay from its clean source snapshot, hide
  /// both real heroes, and claim that pair's transition from the registry.
  /// Shared by the normal interactive `activate()` (drag crossed the threshold)
  /// and the fast-commit synthesis path (`synthesizeOverlaysForCommit`).
  private func buildOverlay(for pair: TrackedPair) {
    guard let detail = pair.detail else { return }
    if pair.overlay != nil { return }

    // Prefer the clean snapshot the registry handed us at adopt time (detail
    // fully on-screen); fall back to a live capture.
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
    // Make the registry's unregister back-flight stand down — we own this
    // pair's transition now (mirrors the `alreadyFlighted` source-flight guard).
    HeroRegistry.shared.markInteractivelyHandled(detail)
  }

  /// Build overlays for a COMMIT that happened before the drag ever crossed
  /// the activation threshold (a very fast swipe). We never tracked the finger,
  /// so each overlay starts at its detail's natural resting frame (where the
  /// captured snapshot was taken) rather than `windowFrame()`, whose model
  /// value may already have jumped to the off-screen popped position on a fast
  /// commit. The caller immediately runs `beginSyncedFinish(cancelled: false…)`,
  /// which flies each overlay onto its list cell's settled frame.
  private func synthesizeOverlaysForCommit() {
    for pair in pairs {
      buildOverlay(for: pair)
    }
    NSLog("[SharedHeroStackPop] synthesizeOverlaysForCommit pairs=\(pairs.count)")
  }

  private func driveOverlays(translation: CGFloat, progress p: CGFloat) {
    for pair in pairs {
      guard let ov = pair.overlay else { continue }
      // Source follows the finger: the detail screen slides right by
      // `translation` and the hidden hero rides with it. Destination is the
      // LIVE list thumbnail — it is parallax-sliding in from the left for the
      // whole gesture, so we read its window frame EVERY frame rather than
      // pinning a stale rect. The lerp keeps the overlay locked between the two
      // real (moving) anchors.
      let followed = pair.sourceRect.offsetBy(dx: translation, dy: 0)
      let dest = liveDestRect(pair) ?? followed
      ov.frame = Self.lerpRect(followed, dest, p)
      ov.layer.cornerRadius = pair.sourceCorner + (pair.destCorner - pair.sourceCorner) * p
    }
  }

  /// Begin the post-commit handoff: the detail left the window, so the pop is
  /// committed. Keep the link running to drive the overlays onto the list
  /// thumbnails' live frames until the slide settles.
  private func beginCommit() {
    committing = true
    active = false
    commitDeadline = CACurrentMediaTime() + Self.maxCommitSettleSeconds
    NSLog("[SharedHeroStackPop] beginCommit pairs=\(pairs.count)")
  }

  private func driveCommit() {
    guard !pairs.isEmpty else { finishCommit(); return }
    var allConverged = true
    let tol = Self.settleTolerance
    for pair in pairs {
      guard let ov = pair.overlay else { continue }
      guard let twin = pair.twin, twin.contentView.window != nil else {
        // Destination gone/off-window — nothing to glue to; treat as converged.
        continue
      }
      let live = twin.windowFrame()
      let settled = twin.settledWindowFrame()
      if live != .zero {
        // Glue the overlay onto the real (still-sliding) thumbnail so they move
        // as one. When the slide finishes (live ≈ settled) the crossfade
        // happens with the real hero exactly under the overlay — zero jump.
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
    NSLog("[SharedHeroStackPop] finishCommit pairs=\(pairs.count)")
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
    // Deliberately DO NOT `unmarkInteractivelyHandled`: the details are being
    // torn down and their deferred `commitUnregister` must keep taking the
    // `alreadyFlighted` early-return branch so they don't fire redundant
    // back-flights. The stale entries are cleared by `register` on the next
    // mount.
    self.detail = nil
    self.pairs = []
    self.active = false
    self.committing = false
    self.ready = false
    self.adopted = false
    stopLink()
  }

  /// Run our overlay animations in lock-step with UIKit's finish/cancel
  /// completion after the user releases the swipe. `duration`/`curve` come from
  /// the host nav controller's transition coordinator so we match the page
  /// slide exactly. All pairs animate together; the shared teardown runs once
  /// the last per-pair animation completes.
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
      NSLog("[SharedHeroStackPop] syncedCancel dur=\(dur) pairs=\(live.count)")
      // Fly each overlay back onto its detail hero's resting position in sync
      // with the page sliding back. Keep BOTH real heroes hidden for the whole
      // animation: the list thumbnail (twin) must NOT be revealed here — it's
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
      // Commit: the model frame has jumped to the final settled state, so
      // `twin.windowFrame()` now reports exactly where each list thumbnail will
      // rest. Fly each overlay there over the SAME duration/curve as the page
      // slide, then crossfade to the real (now-settled) thumbnail.
      for pair in live {
        guard let ov = pair.overlay, let detail = pair.detail else { onFinishPairDone(cancelled: false); continue }
        let finalRect = nonZero(pair.twin?.windowFrame())
          ?? nonZero(pair.twin?.settledWindowFrame())
          ?? ov.frame
        NSLog("[SharedHeroStackPop] syncedCommit dur=\(dur) final=\(finalRect)")
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

  /// Per-pair finish-animation completion. Runs the shared teardown once every
  /// pair has finished so the `OverlayHost` host is released exactly once.
  private func onFinishPairDone(cancelled: Bool) {
    finishRemaining -= 1
    guard finishRemaining <= 0 else { return }
    releaseHostIfNeeded()
    finishing = false
    pairs = []
    active = false
    adopted = false
    if cancelled {
      // Stay armed + ready so a subsequent drag re-triggers (the detail never
      // left the window). The next swipe re-adopts each pair.
    } else {
      // Details are being torn down by the pop; keep them marked
      // (`alreadyFlighted`) so their deferred `commitUnregister` stays
      // suppressed and doesn't fire a redundant back-flight.
      detail = nil
      ready = false
      stopLink()
    }
  }

  private func finalizeCancel() {
    NSLog("[SharedHeroStackPop] finalizeCancel pairs=\(pairs.count)")
    // The screen slid back to rest, so each real hero is already at its
    // `sourceRect` and the overlay (translation≈0, progress≈0) sits on top of
    // it — un-hide and remove with no visible jump.
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

  /// The shared overlay host view, retained from `OverlayHost` exactly once per
  /// session (on the first overlay built) and cached so additional overlays
  /// reuse it without incrementing the host count.
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

  /// Un-hide the list cells we hid at adopt time. Used when an adopted gesture
  /// ends WITHOUT ever activating (a tiny swipe). We deliberately do NOT
  /// `unmarkInteractivelyHandled(twin)` here: if a list screen slides back off
  /// it will unregister, and that mark makes its `commitUnregister` stand down
  /// (no spurious back-flight); the mark is consumed there. Clears the tracked
  /// pairs so the next swipe re-adopts cleanly.
  private func restoreTwins() {
    for pair in pairs {
      pair.twin?.setHiddenForFlight(false)
    }
    pairs = []
    adopted = false
  }

  /// Tear down the session immediately, without reversing or completing a
  /// transition. Used when arming a new session or when the tracked hero is no
  /// longer eligible (deallocated, not a popable nav screen, non-interactive
  /// pop).
  private func disarm() {
    stopLink()
    for pair in pairs {
      if active {
        pair.detail?.setHiddenForFlight(false)
        pair.detail.map { HeroRegistry.shared.unmarkInteractivelyHandled($0) }
      }
      // The list cells are hidden from adopt time onward (before `activate`),
      // so restore them on ANY teardown where we'd adopted, not just active.
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

  /// The list thumbnail's LIVE window rect (parallax-sliding), or nil if it
  /// isn't currently usable.
  private func liveDestRect(_ pair: TrackedPair) -> CGRect? {
    guard let twin = pair.twin, twin.contentView.window != nil else { return nil }
    let f = twin.windowFrame()
    return f != .zero ? f : nil
  }

  /// True if `view` is hosted in a `UINavigationController` that has something
  /// to pop AND is not inside a swipe-dismissable sheet (those are owned by
  /// `InteractiveModalReturn`).
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

  /// True if `view`'s host `UINavigationController` is currently running an
  /// INTERACTIVE transition — i.e. the user-driven left-edge swipe-back, as
  /// opposed to a programmatic push or a button-triggered pop (both
  /// non-interactive). This is the signal that distinguishes the gesture we
  /// want to track from every other twin-flight that flows through
  /// `runTwinFlight`.
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

  /// The host `UINavigationController`'s active transition coordinator, used to
  /// observe when the interactive swipe is released and to match its
  /// finish/cancel duration + curve.
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
