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
/// Instead we OBSERVE the real motion and drive our own overlay — like
/// `InteractiveModalReturn`, but horizontal and tracking a LIVE destination:
///   * Armed at push time on the pushed `detail` (destination = list `twin`);
///     stands down if the detail isn't in a popable nav controller.
///   * `translation = live.minX - natural.minX` = how far the screen dragged.
///   * On a rightward drag, hide the real detail + list cell and add an overlay
///     that lerps from the finger-following source to the list cell's LIVE
///     (also-sliding) frame, keeping overlay and list locked — no veer.
///   * On release we keep driving the overlay off the detail's PRESENTATION
///     frame so it stays glued to the real page slide, then crossfade to the
///     real hero once everything settles. Commit vs cancel is read from where
///     the detail actually comes to rest, not from a coordinator flag.
///
/// ## Device-agnostic release detection (the iOS 18 fix)
///
/// We must NOT trust the transition coordinator's interaction-change signal
/// (`isInteractive` / `notifyWhenInteractionChanges`): on iOS 18 + RNS it
/// reports the interactive phase as OVER at the very START of a slow drag, so
/// the overlay snaps to the thumbnail immediately. The PHYSICAL finger lift is
/// instead taken from the driving pan/edge gesture recognizer's `.state`
/// (`.ended`/`.cancelled`/`.failed`) — reliable on both iOS 18 and iOS 26 — with
/// a model-vs-presentation "jump" heuristic as a fallback when no recognizer is
/// found. Once released we sync to the real animation via the presentation layer
/// (no fixed duration), so neither device depends on the coordinator.
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
  /// Tolerance (pt) between a view's live (presentation) and settled (model)
  /// frames that marks an in-flight slide as finished.
  private static let settleTolerance: CGFloat = 1.5
  /// Fraction of the dismiss distance the detail must have travelled, once the
  /// post-release slide settles, to count as a COMMIT rather than a CANCEL.
  private static let commitProgress: CGFloat = 0.5
  /// Model-vs-presentation gap (pt) that flags a release when no driving gesture
  /// recognizer was found: on release the model frame jumps to its final value
  /// while the presentation layer lags, so a large gap means the finger is up.
  private static let releaseJumpThreshold: CGFloat = 60
  /// Ceiling on the post-commit settle wait, so a dest that never settles
  /// (torn down / relaid-out) is still revealed.
  private static let maxCommitSettleSeconds: CFTimeInterval = 1.0
  /// Ceiling on the post-release follow, so a slide that never reports settled
  /// is still finalised.
  private static let maxReleaseSeconds: CFTimeInterval = 1.0

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
  /// settle sampling, and the gesture recognizer we read release from. All
  /// adopted pairs are on the same popping screen and slide with it, so one
  /// suffices.
  private weak var detail: SharedHeroViewImpl?

  /// Every adopted (detail, twin) pair, including the driver's. Secondary
  /// heroes are appended as their twin flights fire.
  private var pairs: [TrackedPair] = []

  private var link: CADisplayLink?
  /// Push has settled and `naturalRect` is valid.
  private var ready = false
  /// A rightward drag is in progress and the overlays are live.
  private var active = false
  /// Finger released; following the detail's PRESENTATION frame each tick until
  /// the page slide settles, then deciding commit vs cancel from its rest spot.
  private var releasing = false
  /// Pop committed: holding the overlays on the list cells until their parallax
  /// slide-in finishes, then handing off. Runs even off-window.
  private var committing = false
  /// The terminal crossfade/teardown is running; ignore any stray tick.
  private var finishing = false

  /// Overlay host retained once per session and shared by all overlays, so the
  /// `OverlayHost` ref-count stays balanced (one `host()` ↔ one `releaseHost()`).
  private var hostView: UIView?
  private var hostRetained = false

  /// The driver's natural resting frame (push settled); drag is measured from it.
  private var naturalRect: CGRect = .zero
  private var dismissRef: CGFloat = 1

  /// Translation at the instant we activated (took the overlay over from the real
  /// hero). The morph fraction is anchored here so the overlay's FIRST frame
  /// equals the hero's last on-screen frame (0% morph) regardless of how far the
  /// page had already slid before we engaged — otherwise it pops by `p` at
  /// takeover, worse the faster the swipe.
  private var activateTranslation: CGFloat = 0

  private var lastX: CGFloat = .greatestFiniteMagnitude
  private var stableFrames = 0
  private var commitDeadline: CFTimeInterval = 0
  private var releaseDeadline: CFTimeInterval = 0

  /// Set once `tryAdoptInteractivePop` confirms a real edge-swipe pop and
  /// suppresses the registry's flight for ≥1 pair. We only `activate()` when
  /// adopted, so a missed detection stays dormant instead of stacking a second
  /// competing overlay on top of the registry's flight.
  private var adopted = false

  // MARK: - Release detection.

  /// The pop's driving gesture recognizer — UIKit's `interactivePopGestureRecognizer`
  /// in the default RNS path, or the screen-edge/pan recognizer for custom
  /// animations. Captured once a drag is under way so we can read the PHYSICAL
  /// finger lift from its `.state` instead of the unreliable transition
  /// coordinator. Weak: it's owned by the nav controller.
  private weak var popRecognizer: UIGestureRecognizer?
  /// Set by `popRecognizer`'s target action the instant it ends/cancels/fails —
  /// the authoritative release edge (a per-tick poll can miss the transient
  /// `.ended`, which reverts to `.possible` almost immediately).
  private var recognizerEnded = false
  /// How the current release was detected, for the on-device logs.
  private var releaseBy = ""

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
    self.releasing = false
    self.committing = false
    self.finishing = false
    self.adopted = false
    self.pairs = []
    self.lastX = .greatestFiniteMagnitude
    self.activateTranslation = 0
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
    guard ready, !releasing, !committing, !finishing else { return false }
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
    if finishing { return }

    // Post-commit FALLBACK: hold the overlays on the list cells until their
    // slide-in finishes, then hand off. Runs even off-window.
    if committing {
      driveCommit()
      return
    }

    guard let detail = detail else { disarm(); return }

    // Post-release: follow the real page slide via the presentation layer.
    if releasing {
      driveRelease(detail: detail)
      return
    }

    // Off-window: before first attach the push is still animating in (wait,
    // bounded); after having attached, the pop completed.
    guard detail.contentView.window != nil else {
      if everAttached {
        if active {
          // Detail left mid-drag with no captured release edge (a very fast
          // commit) — it's gone, so follow it straight into the commit handoff.
          releaseBy = "offwindow"
          beginRelease()
        } else if adopted {
          // Fast interactive pop that committed before crossing the activation
          // threshold: synthesise overlays and commit (keeping the return
          // in-controller so the details' unregister won't fire a late flight).
          heroLog(HeroLog.stackPop, "committed before activation — synthesizing")
          synthesizeOverlaysForCommit()
          releaseBy = "offwindow-preactivate"
          beginRelease()
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

    // As soon as we're adopted, latch onto the driving gesture recognizer so its
    // `.state` (not the lying coordinator) tells us when the finger lifts.
    if adopted { captureRecognizer() }

    // The MODEL frame jumps straight to its final (fully-dismissed) value the
    // instant the interactive pop begins — only the PRESENTATION layer follows
    // the finger. Track translation off presentation, falling back to the model
    // frame when no presentation layer exists yet (nothing animating).
    let presLive = detail.presentationWindowFrame()
    let tracked = presLive != .zero ? presLive : live
    let translation = tracked.minX - naturalRect.minX

    if !active {
      // The gesture can end BEFORE we cross the activation threshold (a tiny or
      // very fast swipe). Decide from motion: near rest → cancel/restore;
      // already moved far → synthesise overlays and commit.
      if adopted, releaseDetected(detail: detail, modelFrame: live) {
        if translation > Self.activateThreshold {
          heroLog(HeroLog.stackPop, "released before activation → commit by=\(releaseBy) transl=\(rd(translation))")
          synthesizeOverlaysForCommit()
          beginRelease()
        } else {
          heroLog(HeroLog.stackPop, "released before activation → restore by=\(releaseBy) transl=\(rd(translation))")
          restoreTwins()
        }
        return
      }
      // A pop is a RIGHTWARD drag, and only once `adopted`. The gate stops a
      // missed detection from stacking our overlay on the registry's flight; a
      // button-pop fade doesn't move in x, so it never trips this anyway.
      guard adopted && translation > Self.activateThreshold else { return }
      activateTranslation = translation
      activate()
      // Fall through (NO return) to drive the overlay THIS tick. Positioning it
      // at the current translation hands off exactly where the sliding page
      // already is; returning here would leave it parked at rest for one frame
      // and then jump to catch the finger — the start-of-swipe "snap".
    }

    // ACTIVE. Drive the overlays off the finger-following PRESENTATION frame
    // (the model frame has already jumped to the dismissed value) until the
    // recognizer reports the physical lift. Both the detail and the re-entering
    // list cell parallax-slide via their presentation layers, so read both
    // on-screen.
    if releaseDetected(detail: detail, modelFrame: live) {
      beginRelease()
      driveRelease(detail: detail)
      return
    }

    let p = morphProgress(translation)
    logDrag(translation: translation, progress: p)
    driveOverlays(translation: translation, progress: p, releasePhase: false)
  }

  // MARK: - Release detection helpers.

  /// Latch the recognizer physically driving the pop and start watching its
  /// state edge. One-shot per session; the target is removed on every teardown.
  private func captureRecognizer() {
    guard popRecognizer == nil, let driver = detail else { return }
    guard let gr = Self.findActivePopRecognizer(driver.contentView) else { return }
    popRecognizer = gr
    recognizerEnded = false
    gr.addTarget(self, action: #selector(popRecognizerChanged(_:)))
    heroLog(HeroLog.stackPop, "captured recognizer=\(String(describing: type(of: gr))) state=\(gr.state.rawValue)")
  }

  @objc private func popRecognizerChanged(_ gr: UIGestureRecognizer) {
    switch gr.state {
    case .ended, .cancelled, .failed:
      recognizerEnded = true
    default:
      break
    }
  }

  private func releaseRecognizerTarget() {
    popRecognizer?.removeTarget(self, action: #selector(popRecognizerChanged(_:)))
    popRecognizer = nil
    recognizerEnded = false
  }

  /// True once the finger has physically lifted. Primary signal: the driving
  /// recognizer's `.state`. Fallback (no recognizer found): the model frame has
  /// jumped far ahead of the presentation layer, which only happens on release.
  private func releaseDetected(detail: SharedHeroViewImpl, modelFrame: CGRect) -> Bool {
    if let gr = popRecognizer {
      if recognizerEnded {
        releaseBy = "gesture"
        return true
      }
      switch gr.state {
      case .ended, .cancelled, .failed:
        releaseBy = "gesture-poll"
        return true
      default:
        // Recognizer is present and still tracking → definitely not released;
        // do NOT fall through to the divergence heuristic (avoids false positives).
        return false
      }
    }
    let pres = detail.presentationWindowFrame()
    if pres != .zero, abs(modelFrame.minX - pres.minX) > Self.releaseJumpThreshold {
      releaseBy = "divergence"
      return true
    }
    return false
  }

  // MARK: - Interactive overlay lifecycle.

  private func activate() {
    guard !pairs.isEmpty else { return }
    for pair in pairs {
      buildOverlay(for: pair)
    }
    active = true
    heroLog(HeroLog.stackPop, "activate pairs=\(pairs.count) natural=\(naturalRect) dismissRef=\(rd(dismissRef))")
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
  /// `windowFrame()`, whose model value may already have jumped off-screen.
  private func synthesizeOverlaysForCommit() {
    for pair in pairs {
      buildOverlay(for: pair)
    }
    heroLog(HeroLog.stackPop, "synthesizeOverlaysForCommit pairs=\(pairs.count)")
  }

  /// Drive every overlay between its finger-following source and the list cell.
  ///
  /// During the DRAG the destination is the cell's SETTLED (natural resting)
  /// rect — parallax-INVARIANT. The underlying list screen parallax-slides in,
  /// and its presentation frame only becomes parallax-valid at a discrete moment
  /// (when UIKit cross-fades the back-button label); targeting it mid-drag makes
  /// `dest` jump left+down and the hero lurch. The settled rect is stable, and at
  /// p→1 the cell's live position converges to it anyway, so no landing mismatch.
  ///
  /// In the RELEASE phase (`releasePhase`) we DO follow the live presentation
  /// cell, so the hero rides the page's slide-in and lands in sync with its list
  /// context for the handoff.
  private func driveOverlays(translation: CGFloat, progress p: CGFloat, releasePhase: Bool) {
    for pair in pairs {
      guard let ov = pair.overlay else { continue }
      let followed = pair.sourceRect.offsetBy(dx: translation, dy: 0)
      let dest = (releasePhase ? presentationDestRect(pair) : settledDestRect(pair)) ?? followed
      ov.frame = Self.lerpRect(followed, dest, p)
      ov.layer.cornerRadius = pair.sourceCorner + (pair.destCorner - pair.sourceCorner) * p
    }
  }

  // MARK: - Post-release follow.

  /// Enter the post-release phase: the link keeps running and `driveRelease`
  /// glues the overlays to the detail's PRESENTATION frame (the model frame has
  /// jumped to final) until the page slide settles.
  private func beginRelease() {
    guard !releasing, !committing, !finishing else { return }
    releasing = true
    active = false
    releaseDeadline = CACurrentMediaTime() + Self.maxReleaseSeconds
    heroLog(HeroLog.stackPop, "release by=\(releaseBy) pairs=\(pairs.count) — following presentation")
  }

  /// Follow the real post-release slide via the presentation layer, then decide
  /// commit vs cancel from where the detail comes to rest.
  private func driveRelease(detail: SharedHeroViewImpl) {
    guard !pairs.isEmpty else { finalizeCancel(); return }

    // Detail gone → definitely committed; hand the overlays to the list cells.
    if detail.contentView.window == nil {
      heroLog(HeroLog.stackPop, "release: detail off-window → commit")
      beginCommit()
      driveCommit()
      return
    }

    let pres = detail.presentationWindowFrame()
    let model = detail.windowFrame()
    let frame = pres != .zero ? pres : model
    let translation = frame.minX - naturalRect.minX
    let p = morphProgress(translation)
    driveOverlays(translation: translation, progress: p, releasePhase: true)

    // Settled once the presentation layer catches up to the model (the
    // completion animation has finished).
    let settled = pres == .zero
      || (abs(pres.minX - model.minX) < Self.settleTolerance
          && abs(pres.minY - model.minY) < Self.settleTolerance)
    let timedOut = CACurrentMediaTime() > releaseDeadline
    guard settled || timedOut else { return }

    // Commit vs cancel from MOTION, not a coordinator flag: the detail either
    // slid past the commit line (popped) or returned toward its start (cancel).
    if translation > dismissRef * Self.commitProgress {
      heroLog(HeroLog.stackPop, "release settled → commit transl=\(rd(translation)) settled=\(settled) timedOut=\(timedOut)")
      beginCommit()
      driveCommit()
    } else {
      heroLog(HeroLog.stackPop, "release settled → cancel transl=\(rd(translation)) settled=\(settled) timedOut=\(timedOut)")
      finalizeCancel()
    }
  }

  // MARK: - Commit handoff.

  /// Switch from finger/presentation following to gluing each overlay onto its
  /// list cell until the cell's own slide-in finishes.
  private func beginCommit() {
    guard !committing, !finishing else { return }
    committing = true
    active = false
    releasing = false
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
      // The list cell's MODEL frame already sits at its settled position; the
      // slide-in lives in the PRESENTATION layer. Glue the overlay to the
      // on-screen (presentation) cell so they move as one; when the slide
      // finishes (presentation ≈ model) the crossfade lands with the real hero
      // exactly under the overlay — zero jump.
      let model = twin.windowFrame()
      let pres = twin.presentationWindowFrame()
      let liveRect = pres != .zero ? pres : model
      if liveRect != .zero {
        ov.frame = liveRect
        ov.layer.cornerRadius = pair.destCorner
      }
      let converged = liveRect != .zero && model != .zero
        && abs(liveRect.origin.x - model.origin.x) < tol
        && abs(liveRect.origin.y - model.origin.y) < tol
        && abs(liveRect.width - model.width) < tol
        && abs(liveRect.height - model.height) < tol
      if !converged { allConverged = false }
    }
    if allConverged || CACurrentMediaTime() > commitDeadline {
      finishCommit()
    }
  }

  private func finishCommit() {
    finishing = true
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
    releaseRecognizerTarget()
    // Do NOT `unmarkInteractivelyHandled`: the details are being torn down and
    // their deferred `commitUnregister` must keep early-returning so they don't
    // fire redundant back-flights. `register` clears the stale marks on remount.
    self.detail = nil
    self.pairs = []
    self.active = false
    self.releasing = false
    self.committing = false
    self.finishing = false
    self.ready = false
    self.adopted = false
    stopLink()
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
    releaseRecognizerTarget()
    active = false
    releasing = false
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
    releasing = false
    releaseRecognizerTarget()
  }

  /// Tear the session down immediately without reversing or completing a
  /// transition. Used when arming a new session or when the hero is no longer
  /// eligible (deallocated, not a popable screen, non-interactive pop).
  private func disarm() {
    stopLink()
    for pair in pairs {
      if active || releasing {
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
    releaseRecognizerTarget()
    pairs = []
    detail = nil
    ready = false
    active = false
    releasing = false
    committing = false
    finishing = false
    adopted = false
    activateTranslation = 0
  }

  // MARK: - Helpers.

  /// The list cell's SETTLED (parallax-invariant) rect — the natural spot it
  /// rests at once the re-entering screen finishes sliding in. Used as the drag
  /// destination so the morph target never jumps with the parallax slide.
  private func settledDestRect(_ pair: TrackedPair) -> CGRect? {
    guard let twin = pair.twin, twin.contentView.window != nil else { return nil }
    let f = twin.settledWindowFrame()
    return f != .zero ? f : nil
  }

  /// The list cell's on-screen PRESENTATION rect, used after release where the
  /// model frame has jumped to its settled value and only the presentation layer
  /// reflects the slide-in. Nil if unusable.
  private func presentationDestRect(_ pair: TrackedPair) -> CGRect? {
    guard let twin = pair.twin, twin.contentView.window != nil else { return nil }
    let p = twin.presentationWindowFrame()
    if p != .zero { return p }
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
  /// pop. Read ONLY at adopt time (gesture START), where the coordinator's
  /// `isInteractive`/`initiallyInteractive` flags are still trustworthy on iOS
  /// 18 — it's the per-tick interaction-CHANGE signal that lies, which we no
  /// longer use. This distinguishes the gesture we track from every other
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

  /// Find the gesture recognizer physically driving the pop. Scans UIKit's
  /// `interactivePopGestureRecognizer` (the default RNS path), the nav view's
  /// recognizers, and the RNSScreenStackView's recognizers (custom-animation
  /// path), preferring whichever is currently tracking (`.began`/`.changed`).
  private static func findActivePopRecognizer(_ view: UIView) -> UIGestureRecognizer? {
    var nav: UINavigationController?
    var responder: UIResponder? = view
    while let r = responder {
      if let n = r as? UINavigationController { nav = n; break }
      responder = r.next
    }

    var candidates: [UIGestureRecognizer] = []
    if let nav = nav {
      if let ip = nav.interactivePopGestureRecognizer { candidates.append(ip) }
      if let grs = nav.view.gestureRecognizers { candidates.append(contentsOf: grs) }
    }
    var v: UIView? = view
    while let cur = v {
      if String(describing: type(of: cur)).contains("ScreenStack"),
         let grs = cur.gestureRecognizers {
        candidates.append(contentsOf: grs)
      }
      v = cur.superview
    }

    // Only latch a recognizer that's physically TRACKING right now; returning a
    // dormant fallback risks latching a disabled recognizer (custom-animation
    // setups disable `interactivePopGestureRecognizer`), so `captureRecognizer`
    // simply retries next tick until the real driver is tracking.
    return candidates.first { $0.state == .began || $0.state == .changed }
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

  /// Morph fraction anchored at the activation point: 0 at takeover, 1 at full
  /// dismiss. Anchoring (rather than `translation / dismissRef`) makes the
  /// overlay's first frame sit exactly on the real hero, so there's no pop at
  /// handoff no matter how far the page had already slid when we engaged.
  private func morphProgress(_ translation: CGFloat) -> CGFloat {
    let denom = max(1, dismissRef - activateTranslation)
    return max(0, min(1, (translation - activateTranslation) / denom))
  }

  private func rd(_ v: CGFloat) -> CGFloat { (v * 10).rounded() / 10 }

  // MARK: - Throttled drag logging.

  /// Last logged drag translation, so the per-frame drive logs only fire on a
  /// meaningful change (a handful of lines per gesture, not 60/sec).
  private var lastLoggedTranslation: CGFloat = .greatestFiniteMagnitude
  private func logDrag(translation: CGFloat, progress p: CGFloat) {
    guard abs(translation - lastLoggedTranslation) >= 24 else { return }
    lastLoggedTranslation = translation
    let grState = popRecognizer?.state.rawValue ?? -1
    // `settled` (the drag target) must stay CONSTANT across the swipe; `pres`
    // (the live parallax cell) is the one that jumps mid-drag — log both so a
    // future shift is immediately attributable.
    let settled = pairs.first.flatMap { settledDestRect($0) } ?? .zero
    let pres = pairs.first.flatMap { presentationDestRect($0) } ?? .zero
    heroLog(HeroLog.stackPop, "drag transl=\(rd(translation)) p=\(rd(p)) grState=\(grState) settled=\(settled) pres=\(pres)")
  }
}
