# Lessons Learned

> A living dev journal for `react-native-shared-hero` — the bugs, surprises, dead-ends,
> and design decisions we hit, and the generalizable takeaways. **Not a changelog**
> (git does that). This is the "things we wish we'd known earlier" file.

## How to use this file
- Append new entries at the top (newest first).
- Add an entry whenever something non-obvious costs real time, or whenever a real
  design decision is made. Keep entries tight: a few sentences per field.
- This is a habit, not a gate — keep it cheap to add to.

For the design rationale behind the architecture these lessons reference, see
[ARCHITECTURE.md](./ARCHITECTURE.md).

## TL;DR — headline lessons
1. **Shared-element transitions are a window/lifecycle problem, not an animation problem.** Most of the pain came from *where* a view lived (which `UIWindow`/Dialog) and *when* it registered/unregistered — not from the easing.
2. **An overlay must live in (or above) the destination's window.** iOS gets this for free with a high-level `UIWindow`; everything cross-window (core `<Modal>`, Dialog) breaks until the overlay is hosted window-aware.
3. **Interactive UIKit transitions must be driven by the gesture, never by a timer.** Detect release via `transitionCoordinator`, sync to its duration/curve, and respect the model-vs-presentation-layer split.
4. **When you build the real mechanism, delete the band-aids it replaces.** Leftover patches keep firing on fallback paths and cause new, weirder bugs.
5. **RN's core `<Modal>` is a separate, uncoordinated window.** It can't be frame-locked to the navigator the way `react-native-screens` presentations can; design around that instead of fighting it.
6. **The host navigator is an uncoordinated collaborator, not an enemy you can ignore.** `react-native-screens` reparents our subtree within a single tick (churn), parallax-translates the previous screen during transitions, and dumps a main-thread spike when its own animation ends — every one of those produced a distinct class of bug. Defend against all three (defer-unregister churn-cancel, settled-vs-live frames, RenderNode-driven overlays).
7. **A flight is only as good as its snapshot.** Half the "blank/ghost/snap" bugs were a snapshot captured at the wrong instant (after children detached, mid-resize, before the image loaded) — not the animation.

## Categories
`iOS/UIKit` · `Cross-window/Modal` · `Android` · `Lifecycle` · `Decision` · `DX`

---

## 2026-06-12 — [iOS/UIKit] Very fast edge-swipe pop "restored" then jumped — pre-activation commit/cancel was guessed from the lagging presentation frame

**Symptom**: Tap a list cell → detail, then swipe-back from the left edge **very fast**. The detail fully dismissed and the list fully settled (cell back at its natural spot), and only THEN the cell snapped to its detail-screen position and ran a flight from there. Slow/normal swipes were fine.

**Root cause**: On a hard flick the driving gesture recognizer ends before `captureRecognizer()` can latch it (`findActivePopRecognizer` only returns a recognizer in `.began`/`.changed`), so `InteractiveStackPop` infers release from the `"divergence"` heuristic. The pre-activation branch then classified commit vs cancel from the *instantaneous presentation translation* — which reads ~0 on a flick (the presentation layer lags the finger, while the model frame is pinned at the dismissed value for the entire interactive transition). `transl≈0 ≤ activateThreshold` took the **cancel/restore** path on what was actually a commit. The controller stood down, the detail unregistered, and the registry's *time-driven* `unregister-twin` back-flight fired after the screen had already settled — gluing the overlay to the detail rect and flying late (the jump).

**Fix**: Don't guess commit vs cancel at the release instant when release was detected via `"divergence"`. Synthesize the overlays and hand off to the release-follow phase (`beginRelease` + `driveRelease`), which reads commit vs cancel from where the page actually comes to **rest** — the same authority the activated path already uses. The `translation > activateThreshold` fast-commit and the recognizer-confirmed tiny-cancel (`restoreTwins`) paths are unchanged.

**Lesson**: During a UIKit interactive transition the model frame sits at the *final* value the whole time and the presentation frame lags the finger, so **neither frame can classify commit vs cancel at the release instant** — only the post-release settle can. Any "decide now from translation" shortcut will misfire on fast input. Route uncertain releases through the settle observer instead of guessing.

## 2026-06-13 — [Android] One text hero of a sibling pair flew late — the blank-bitmap heuristic false-positived on sparse text

**Symptom**: In the Text example, only the "Pacific Shelf" row desynced on back-nav (detail→list): the title settled first, then the subtitle visibly flew *after* it. Every other row was in sync, the *forward* flight was fine, and iOS was fine everywhere. Title length was a red herring — "Pine Cathedral" is just as long and never broke.

**Diagnosis (from logcat)**: Title and subtitle are independent in-place back-flights (Android RNS detaches the detail then re-attaches the list within a tick → `register in-place fire`). The title fired at `attemptsUsed=0 haveContent=true`; the subtitle fired ~133ms (12 frames) later at `attemptsUsed=12 haveContent=false`. The subtitle's source bitmap was logged `blank=true` with `hadStash=false`, so it had no stash and no last-known-good fallback, hit the `inPlace` `CONTENT_WAIT_ATTEMPTS` (12) gate in `HeroRegistry.tryFire`, and burned the whole budget before firing best-effort with a blank overlay.

**Root cause**: `isLikelyBlankBitmap` sampled 5 points in the centre band, assuming "a real hero always has opaque pixels near its centre" — true for opaque image rects, false for text. Glyphs are sparse on a transparent background, and the centre column of a line often lands on a space between words. For the subtitle "Sea stacks at low tide" all five samples hit transparent gaps → the heuristic called a real line of text "blank". That false-blank then (a) blocked the rolling `dispatchDraw` stash (`hadStash=false`) and (b) blocked the `lastKnownSnapshots` fallback, leaving the flight with no content → the content-wait delay. It was deterministic per-string (which is why one specific subtitle tripped it), and titles escaped because their larger/denser glyphs reliably cover a sample point.

**Fix**: Sample a coarse grid spanning the **whole** bitmap (10×10 cell centres) instead of a few centre points; any single opaque sample ⇒ not blank. Scattered glyphs hit several grid cells, so real text reads as non-blank, while a genuinely empty bitmap stays all-transparent. Still ~100 `getPixel` calls — cheap enough for capture/flight-decision time.

**Lesson**: A "is this bitmap empty?" heuristic tuned for opaque images will misfire on text/sparse content, and the misfire isn't cosmetic — it suppresses the snapshot stash *and* the fallback, which on the in-place path turns into a visible per-hero timing delay. Sample the full area, not the centre, and remember that any false "blank" cascades into the snapshot/content-wait machinery.

## 2026-06-12 — [iOS/Android] Text heroes cropped (and then mis-positioned) mid-flight — content mode must be aspect-aware AND not re-anchor

**Symptom (1)**: A `<SharedHero>` wrapping `<Text>` flew fine for square images but a wide title (e.g. "Pine Cathedral") was center-cropped during the flight, rendering as a giant "ne Cathed" before snapping to the real text. Images were immune.

**Symptom (2)** (after the first fix): the subtitle landed too far to the RIGHT on the back-flight (detail→list), then crossfaded to the correct left-aligned text — but the forward flight (list→detail) was fine.

**Root cause**: The flying overlay scaled the source bitmap with `.scaleAspectFill` (iOS) / a `max`-cover matrix (Android) and clipped. The bitmap's intrinsic aspect equals the SOURCE rect; the overlay interpolates toward the DEST rect, so whenever source/dest aspect ratios diverge the content is center-cropped. Images escaped because the examples keep aspect ratios matched (`16/10 ↔ 16/10`), where every content mode is identical; text almost always changes shape. Switching to `scaleAspectFit` stopped the *crop* but introduced *symptom 2*: a tight text box's aspect differs slightly between font sizes (leading doesn't scale with glyph advance), and `aspectFit` **centers** — so when the source box was taller-aspect than the dest (the back direction) the left-aligned text landed inset from the left. Forward, the source was wider-aspect → fit-by-width → left edge at 0 → looked fine. Directionally inconsistent.

**Fix**: Aspect-aware by MODE, and for the tight-box case map box→box directly. `morph`/`zoom`/`auto` keep aspect-FILL (photo container transform — the crop morphs, see 2026-06-06). `snapshot` (default; text & arbitrary content) uses **scale-to-fill** (iOS `.scaleToFill`; Android `ScaleType.FIT_XY`): a tight text box IS its content, so filling it lands the glyphs exactly on the destination box — correct origin, consistent both directions, and never cropped. When aspects already match (the image examples) fill/fit/scaleToFill are identical, so images are untouched.

**Lesson**: For a flown bitmap, the content mode is the whole ball game. `aspectFill` = crop-morph (right for photos, slices text); `aspectFit` = no crop but RE-ANCHORS to center (mis-positions edge-aligned content); `scaleToFill` = maps box→box exactly (right for tight/text boxes, distorts only if the box aspect itself changed). Pick per intent. And a single scaled bitmap still can't represent a content *reflow* (1-line→2-line) — keep text heroes single-line or matching line counts on both ends for a perfectly clean flight.

## 2026-06-12 — [Android] Published build broke on RN 0.84 — `UIManagerHelper.getEventDispatcher` single-arg overload only exists on 0.85+

**Symptom**: A user on RN 0.84.0 (New Architecture) hit a compile error from the **published** package — `SharedHeroView.kt: No value passed for parameter 'uiManagerType'` — while our own freshly-generated test project and the example app built fine.

**Root cause**: The code called the single-arg `UIManagerHelper.getEventDispatcher(ctx)`, which was **added in RN 0.85** (where the two-arg `getEventDispatcher(ctx, uiManagerType)` was simultaneously deprecated). On 0.84 only the two-arg form exists, so the call can't resolve. Our example/test apps were on RN 0.85/0.86, so they never exercised 0.84 — the breakage was invisible on our machines. (Verified against the `v0.84.0` tag's `UIManagerHelper.kt`.)

**Fix**: Call the two-arg `UIManagerHelper.getEventDispatcher(ctx, UIManagerType.FABRIC)` (this is a Fabric view, matching the `getSurfaceId` assumption) — it exists on 0.84, 0.85, **and** 0.86 — wrapped in `@Suppress("DEPRECATION")` so newer builds stay warning-clean. `getSurfaceId(view)` was already cross-version. Kotlin reports all module errors at once and the user saw only this one, so it was the sole incompatibility.

**Lesson**: The library is shipped as source, so it must **compile on every supported RN, not just the example's**. A recent RN in `example/` masks recently-added/removed APIs. Choose the widest-compatible overload, and before publishing, build the native sources against the **minimum** supported RN — a green example build proves nothing about older versions.

## 2026-06-08 — [iOS/UIKit] Interactive edge-swipe back flew to the wrong position because `windowFrame()` reads the model layer

**Symptom**: On a slow left-edge swipe-back, the hero didn't track the finger — it flew immediately to a position that was off (veered left), worse the slower you swiped.

**Diagnosis path**:
1. Pinned the landing to a `destFrameHint` — still wrong.
2. Held the handoff until `windowFrame()` converged — still wrong at normal speed.
3. Realized the underlying screen *parallax-slides* during the gesture, and that on release UIKit snaps the **model** layer to its final value while animating only the **presentation** layer.

**Root cause**: `windowFrame()` is model-layer based, so mid-gesture it reported transforms in flux and on release it had already "jumped" to the end. A time-driven flight can't represent a finger-tracked, cancellable transition.

**Fix**: Replaced the time-driven back-flight with an interactive controller (`ios/InteractiveStackPop.swift`) driven by `CADisplayLink`: track the live frame while the finger is down, detect release when `transitionCoordinator.isInteractive` flips to false, then run a `UIView.animate` synced to `tc.transitionDuration` + `tc.completionCurve`.

**Lesson**: For interactive UIKit transitions, drive the overlay from the gesture and hand off to the transition coordinator on release. Always know whether a geometry API reads the **model** or **presentation** layer — they diverge exactly during the transitions you care about.

## 2026-06-08 — [iOS/UIKit] Leftover `isBackFlight` / `handoffHold` band-aids caused a fast-swipe "jump to top"

**Symptom**: A *fast* edge-swipe committed the pop, then the hero teleported to the top of the screen, hung ~1s, and vanished.

**Root cause**: Two compounding causes. (1) On a fast swipe the display link never observed the 6pt activation threshold, so the controller's "gesture ended before activation" handler treated a **commit** like a **cancel** and bailed. (2) The registry's legacy fallback back-flight then fired, and the old `isBackFlight`/`destFrameHint` band-aid pinned the landing to a stale full-screen rect with `handoffHold` parking it there until timeout.

**Fix**: Branch the pre-activation handler on `tc.isCancelled` (commit synthesizes the overlay and runs the synced finish; cancel restores and stays armed). Then **removed** `isBackFlight`, its fast-fire-to-hint path, `holdHandoffUntilWindowFrameReaches`, and `handoffHold` entirely.

**Lesson**: When a proper mechanism (the interactive controller) takes over a responsibility, delete the stop-gaps that predated it. They survive on rarely-hit fallback paths and resurface as new bugs. Also: a "gesture ended" path must distinguish commit from cancel.

## 2026-06-08 — [iOS/UIKit] Multi-hero interactive pop: secondary hero went time-driven and tore down the primary

**Symptom**: On the *first* multi-step detail (which has a big hero **and** an "Up next" thumbnail, both with twins on the previous screen), a slow swipe-back didn't track — both images flew immediately.

**Root cause**: `InteractiveStackPop` was built around a single armed `detail`/`twin`. The second twin flight failed the `self.detail === detail` guard, fell through to the time-driven `queuePendingFlight`/poll path (firing at the parallax-shifted x), and — worse — reached the unconditional `arm()` at the end of `runTwinFlight`, whose `disarm()` killed the big hero's in-progress interactive session.

**Fix**: Generalized the controller to track a **set** of `TrackedPair`s, all advanced by one display-link tick and finished together; `tryAdoptInteractivePop` now adopts *every* twin flight during the interactive pop (returning `true` so the registry skips both the time-driven flight and the trailing re-`arm()`).

**Lesson**: Interactive controllers must support N shared elements per transition from day one. And watch for a fallthrough path that re-initializes a controller mid-session — adoption must be idempotent and additive, not destructive.

## 2026-06-08 — [Lifecycle] Hide the source/destination at the earliest lifecycle point, restore on every exit

**Symptom**: At swipe start the list cell briefly showed its real thumbnail, then blanked — a visible flash.

**Root cause**: The cell was hidden at `activate()` (6pt threshold), several frames after it re-attached, so its image painted first.

**Fix**: Hide the re-appearing cell synchronously at adopt/register time. Then added restore in *every* terminal path (cancel, commit, disarm, and a "gesture ended before activation" branch) so a cell can never get stranded hidden.

**Lesson**: Hide-for-flight as early as the view exists; pair every hide with a guaranteed restore across **all** exit paths (including the ones you think can't happen). A stuck-hidden view is worse than a one-frame flash.

## 2026-06-08 — [Cross-window/Modal] RN core `<Modal>` is a separate window — four distinct bugs from one root

The core `<Modal>` example was a deliberate probe of cross-window behavior (it renders in its own `RCTModalHostView` UIWindow on iOS / Dialog window on Android, outside the navigator). It surfaced four issues:

**(a) iOS white flash on dismiss** — Root cause: the default opaque Modal window fades out while the content (`{active ? … : null}`) unmounts instantly, flashing white. Fix: `transparent`. **Lesson**: for shared-element work, make the core Modal `transparent` so the library overlay owns the visible transition, never the modal's window backdrop.

**(b) Android bottom gap** — Root cause: an edge-to-edge app, but the Modal's Dialog window didn't extend under the status bar, so its content was short by the status-bar height and, top-anchored, left a gap at the bottom showing the layer beneath. Fix: `statusBarTranslucent` + `navigationBarTranslucent`. **Lesson**: a transparent RN Modal on an edge-to-edge Android app needs the translucent flags to be full-bleed.

**(c) Android forward flight invisible (blank-then-pop)** — Root cause: `OverlayHost.resolveOverlay(context)` walked up to the **Activity** window and added the overlay there — *below* the Modal's Dialog window — so the flight animated fully occluded. Fix: added `resolveOverlay(view)` that hosts in the destination view's own window (`view.rootView` decor). **Lesson**: an overlay must live in the same or a higher window than its destination. iOS avoids this by using a `UIWindow` at level 2001; Android needs explicit window-aware resolution.

**(d) iOS dismiss blank-gap + teleport-to-top** — Root cause: with `animationType="none"` the modal window vanishes instantly, but the cross-window match-pass back-flight only paints ~4 runloop ticks later, and the destination cell was hidden a tick before the overlay appeared. Fix: hide the re-appearing cell on `register`, and fire the match-pass flight synchronously in `runMatchPass` when the destination is already settled (matches the cached hint) — committing hide + first overlay frame in the same tick. **Lesson**: an instant window teardown leaves no animation to mask timing gaps; paint the overlay at the earliest possible tick and order the hide and the first paint in the *same* runloop pass.

## 2026-06-08 — [Decision] Core `<Modal>` dismiss: keep it a simple fly-back, don't fight the window

**Context**: We iterated the core-Modal dismiss three ways: (1) fly-back with `animationType="none"` (looked abrupt), (2) slide the modal down carrying the hero with the return-flight suppressed (showed **two copies** of the image — the riding hero plus the list thumbnail), (3) back to a clean fly-back.

**Decision**: Dismiss = content unmounts immediately (chrome disappears at once), the hero flies back to the thumbnail as a normal return-flight, and the now-empty `transparent` window's slide-out is invisible. `animationType="slide"` is kept only for the *open* entrance.

**Why**: The library keys flights off mount/unmount, and a core `<Modal>`'s window animation is **not** coordinated by the navigator (unlike `react-native-screens` presentations). Keeping content mounted to slide it out delays/duplicates the hero. A native-stack-quality "chrome slides while hero flies" needs coordination the core Modal can't provide; chasing it is fragile.

**Lesson**: Match the UX ambition to what the platform primitive can actually coordinate. For an uncoordinated separate window, the robust shared-element pattern is "unmount immediately, let the library's flight be the whole transition."

## 2026-06-08 — [Decision] `returnFlightEnabled` — scope a behavior toggle to a single read site

**Context**: One experiment needed a hero to *not* produce a return-flight on unregister. The toggle could, in principle, perturb every flight path.

**Decision**: Added a `returnFlightEnabled` prop (default `true`) threaded through JS spec/types/wrapper and both native configs, but **read in exactly one place per platform** — the unregister/back-flight path — as `if (!enabled) { cleanup; return }`. On iOS the value is captured at `unregister` time and carried on `PendingUnregister` (config can reset before the deferred commit).

**Why**: With the default and the single read site, the branch is never taken for any other hero, so it's a provable no-op for push/pop, modals, in-place, etc.

**Lesson**: When adding an opt-out that could touch many code paths, default it to current behavior and confine the read to one site. "Provably a no-op everywhere else" is worth more than cleverness. (We later stopped using it in the example, but kept it as a general escape hatch.)

## 2026-06-08 — [DX] These bugs are only visible in a native build, and the logs are the debugger

**Symptom**: Repeated cycles of "looks wrong" with no JS error — the interesting state lived in Swift/Kotlin.

**Lesson**: Native changes (`ios/`, `android/`) cannot be validated by a Metro reload; you must rebuild via Xcode/Gradle. Lean on the heavy tagged `NSLog`/`Log.d` traces (`SharedHeroRegistry`, `SharedHeroFlight`, `SharedHeroStackPop`, `SharedHeroChain`) and frame-by-frame screen recordings — the precise rects in the logs (e.g. a landing of `(-98.5, …)`) are what actually localize these bugs. Keep that instrumentation.

## 2026-06-07 — [Cross-window/Modal] Native sheet swipe-down dismiss: suppress and late-fly both fail → build `InteractiveModalReturn`

**Symptom**: Dismissing a `presentation: 'modal'`/`'formSheet'` sheet by swiping it down produced either no hero return, or a late, redundant full-width image that popped in at the top and flew down *after* the list had already settled. The Dismiss button was fine.

**Root cause**: React-Navigation unmounts a swipe-dismissed sheet only at the **end** of the gesture (button dismiss unmounts at the *start*, so its flight overlaps the slide). Anything keyed off unregister is therefore necessarily late. Frame-substitution and outright suppression (`snap.frame.midY >= screenHeight`) were both tried and neither gives a real shared-element feel.

**Decision/Fix**: New `ios/InteractiveModalReturn.swift` — a `CADisplayLink` controller armed on every forward modal flight. It reads the detail hero's live `windowFrame().minY` vs the natural rest position captured once the present settles; that delta *is* the drag (works whether UIKit moves the sheet by transform or frame). It flies an overlay that tracks the finger and lands on the twin's `settledWindowFrame()`, marking the hero `interactivelyHandled` so the registry's time-driven back-flight stands down.

**Lesson**: For a native sheet you don't own, don't predict dismiss-vs-cancel — observe the real sheet motion every frame and reconcile to wherever it actually ends. Capturing the rest position needs an `everAttached`/bounded-wait gate because the detail is off-window during the present. (This is the modal sibling of the `InteractiveStackPop` edge-swipe work in the entries above.)

## 2026-06-07 — [Android] Spring flight had no bounce — `minimumVisibleChange` was in pixel units

**Symptom**: In "Spring vs duration", duration=360ms was smooth but spring barely sprang (a tiny bounce on open, none on dismiss); iOS was fine.

**Root cause**: The Android flight drives a normalized `[0,1]` progress through `SpringAnimation`/`FloatValueHolder` but kept the default `minimumVisibleChange = MIN_VISIBLE_CHANGE_PIXELS` (1.0), calibrated for pixel magnitudes. Against a 0→1 range the settle threshold (~0.75 in progress units) declared the spring "done" before any overshoot could play. The `damping: 16, stiffness: 200` config was correct; the threshold cut the motion short.

**Fix**: `minimumVisibleChange = DynamicAnimation.MIN_VISIBLE_CHANGE_SCALE` (0.002) in `runSpringFlight`. The existing `t.coerceIn(0f, 1.2f)` already allowed the overshoot.

**Lesson**: When you reuse a physics animator on a normalized value, set its visible-change threshold to that value's scale — a "no bounce" spring is often a threshold-units bug, not a physics one.

## 2026-06-07 — [Android] In-place toggle blank-then-snap — Fresco releases the drawable before we snapshot

**Symptom**: The Android in-place toggle (including cold launch / first tap) went blank for several frames on tap, then the destination snapped in at full size with no morph. Later toggles were better once the image had painted.

**Root cause**: The in-place path is the only one that relies on a snapshot captured as the **source** unmounts. But a `ViewGroup` detaches its children first, and Fresco releases the `<Image>` drawable in the child's `onDetachedFromWindow`, so by the time `SharedHeroView.onDetachedFromWindow` ran, `draw(Canvas)` produced a blank bitmap. (`dispatchDetachedFromWindow` is package-private and can't be overridden.)

**Fix**: Keep a rolling stash captured in `dispatchDraw` (which fires when the network image paints), throttled with a reentrancy guard and an `isLikelyBlankBitmap` gate; promote every non-blank capture into a per-key `lastKnownSnapshots` fallback. Cold-launch first tap has no rolling stash yet, so a forced posted-frame capture plus the last-known-good fallback cover it.

**Lesson**: Capture the source bitmap while it's still attached and painted; a detach-time capture races the image pipeline. Keep both a rolling stash and a per-key last-known-good so a flight never flies an invisible bitmap.

## 2026-06-07 — [Android] In-place corner radius lost mid-flight — `clipToOutline` is baked into the display list

**Symptom**: After the corner-radius rework, the Android in-place overlay flew square and only snapped to rounded at the very end.

**Root cause**: The overlay animates via per-frame `translationX/Y` + `scaleX/Y` on its RenderNode without re-recording, but `clipToOutline` clipping is captured **into** the display list when the layer is recorded; a `PorterDuff.DST_IN` mask is likewise a no-op under hardware acceleration without a software/offscreen buffer. So the round clip applied only at record time, not per frame.

**Fix**: Drive `clipToOutline = true` with a per-frame `ViewOutlineProvider` round-rect, recomputing the radius (divided by the current scale) and calling `invalidateOutline()` each frame so the GPU re-applies the rounded clip throughout the flight.

**Lesson**: Properties recorded into a RenderNode display list (clips, outlines) don't follow per-frame transform animations — re-issue them every frame or they freeze at their recorded value.

## 2026-06-07 — [Decision] `auto`/`zoom` aliased to `morph`; iOS 18 system-zoom deferred

**Context**: `mode="zoom"` is meant to hand the push/pop to UIKit's iOS 18 `UIViewController.preferredTransition = .zoom(...)`, and `mode="auto"` to pick system-zoom-when-available else the library engine. In v1 the user (correctly) saw no difference — both alias `morph`.

**Decision**: Keep `auto`/`zoom` aliased to `morph` and leave `ios/SystemZoomBridge.swift` a documented stub for a future v2.

**Why**: `.zoom(...)` must be set on the destination view controller **before** `react-native-screens` pushes it, which fights this library's deliberately router-agnostic, view-level hooks; doing it right needs an eager pre-push hook and careful RNS-lifecycle research — not worth the risk for v1.

**Lesson**: Ship an honest alias plus a labelled stub rather than a half-wired "system" path, and never claim a mode is implemented when it isn't.

## 2026-06-07 — [Decision] Example-app restructure: cut the unimplemented mode, add virtualization + multi-step

**Context**: With `auto`/`zoom` aliased to `morph`, the AutoMode example demonstrated nothing; there was no coverage for list virtualization or nested drill-downs; and example titles carried "Phase 1 / Virtualized / Phase 2" badges.

**Decision**: Removed the AutoMode example (native `SystemZoomBridge` stub kept), added a virtualized `FlatList` example (~60 seed items) and a multi-step nested-navigation example (`multi-${id}` ids, `navigation.push` so steps stack), and dropped the phase/virtualized badges.

**Why**: Examples should demonstrate real, working behavior and exercise the hard cases (recycling, simultaneously-mounted steps); roadmap badges leaked internal language into a user-facing demo.

**Lesson**: Keep the demo honest and load-bearing — every example should prove a real capability; delete the ones that don't.

## 2026-06-06 — [iOS/UIKit] GestureReturn drag-to-dismiss did nothing on iOS — the `ScrollView` ate the pan

**Symptom**: In GestureReturn, dragging the hero down didn't dismiss on iOS (Android was fine); only the nav-bar back button worked.

**Root cause**: The hero's `PanResponder` was nested in a `ScrollView`; on iOS the ScrollView's native pan recognizer (it bounces even at offset 0) wins the downward drag, so `onPanResponderMove`/`Release` never fired and `nav.goBack()` was never called. Android's responder negotiation lets the JS `PanResponder` win.

**Fix**: The content fit on screen, so the `ScrollView` was replaced with a plain `View` (JS-only) — no gesture competition. (A Dismiss button was added to the form-sheet example in the same pass.)

**Lesson**: A JS `PanResponder` inside a scrollable competes with the platform scroll recognizer, and iOS resolves that contest differently than Android. If you don't need scrolling, don't nest the draggable in a `ScrollView`.

## 2026-06-06 — [Cross-window/Modal] iOS modal opened with no forward flight — the destination is off-window during the present

**Symptom**: Tapping a hero on the native-modal / transparent-modal examples opened the modal with no fly-in (Android was fine).

**Root cause** (from logs): the destination hero registers and fires `runTwinFlight` from `updateProps` **before** it attaches to a window. For a push the dest attaches within the poll budget; `react-native-screens` keeps a presented UIKit modal's content **off-window until the present animation finishes**, so `pollOnce` burned all 120 back-to-back `DispatchQueue.main.async` hops (a fraction of a second) → "gave up waiting for dest layout" → flight dropped; the dest attached a moment later, too late.

**Fix**: Split the poll into "waiting to attach" vs "waiting to settle". While `everAttached` is false it keeps the flight queued **without** consuming the layout-settle budget, bounded by a wall-clock `attachDeadline` (`maxAttachWaitSeconds`) so a never-attaching dest unhides instead of staying hidden.

**Lesson**: A poll budget must distinguish "not on a window yet" from "on-window but laying out" — a modal present legitimately holds the destination off-window far longer than a push does.

## 2026-06-06 — [Cross-window/Modal] iOS modal button-dismiss produced no back-flight — the twin is off-window too

**Symptom**: Dismissing the native modal via its Dismiss button just closed it, with no return flight.

**Root cause**: The mirror of the forward bug. On dismiss the detail unregisters with a valid `baseline`, but the back-flight's destination (the list thumbnail) is still off-window behind the modal, so `commitUnregister` finds no on-window twin and the match-pass never fires.

**Fix**: Hold the back-flight and fire it once the list re-attaches as the modal dismisses, reusing the forward fix's wall-clock-bounded pre-attach wait (`everAttached`/`attachDeadline`) in the unregister/back-flight path.

**Lesson**: Both directions of a cross-window transition can have an off-window endpoint — apply the same attach-wait machinery to register (forward) and unregister (back).

## 2026-06-06 — [Android] Arc-path aspect-ratio "snap" — the overlay didn't morph the crop

**Symptom**: Android arc-path showed a visible square→rectangle (and reverse) aspect jump at the flight boundary; iOS was smooth.

**Root cause**: List tiles are square crops, the detail hero is a wide rectangle. The Android overlay kept one aspect/crop and hard-swapped to the destination aspect when the real view took over, instead of morphing. iOS's snapshot scales aspect-fill, so its crop morphs smoothly.

**Fix**: Match the overlay snapshot's scaleType/aspect handling to source↔dest so the crop interpolates across the flight (and reverse on dismiss), as on iOS.

**Lesson**: A shared-element morph must interpolate the image's crop/aspect, not just its frame — otherwise the eye catches a content "snap" at the handoff.

## 2026-06-02 — [DX] The "image won't show on launch" turned out to be the network, not a bug

**Symptom**: The iOS in-place toggle sometimes showed no image on open; it was chased as a snapshot/lifecycle bug.

**Root cause**: The remote `picsum.photos` images simply hadn't loaded (flaky network) — not a library defect. The user confirmed it, and the exploratory changes were reverted.

**Lesson**: Remote-image demos let network failures masquerade as transition bugs. Confirm the asset actually loaded before instrumenting the native path, and be ready to revert speculative fixes for a non-bug.

## 2026-06-01 — [iOS/UIKit] In-place toggle saga: torn baseline, first-tap left-jump, and the one-frame blink

**Symptom**: Toggling the in-place hero: no animation at first; then the first tap grew from ~100pt to the left; then each toggle flashed small→big (or big→small) before animating; then a one-frame blank.

**Diagnosis path**:
1. The baseline came out as "small size at the *large* origin" — off by exactly `(320−120)/2 = 100pt`.
2. A position-based in-place detector mistook RNS parallax for a move and fired ghost flights.
3. The first tap had no recorded frame at all.
4. `pollInPlace` hid the view a tick *after* the new layout had already rendered.

**Root cause**: The flight's source rect was captured from a torn live render (`prepareToLeaveWindow` ran mid-resize: the shim was already at the new x while `contentView.bounds` was still the old size). Detection must key on **size**, not position (parallax shifts position transiently). `lastStableWindowFrame` was never recorded before the first tap (the initial `updateLayoutMetrics` fires off-window). And the async hide leaked one rendered frame of the destination state.

**Fix**: Capture the baseline in `unregister` (while the stash is still valid) and carry it on `PendingUnregister`; record a stable frame from layout-metrics **and** on `didMoveToWindow`; trigger in-place on size change only (`inPlaceChangeThreshold`); and fire `FlightEngine.run` **synchronously** from `notifyLayoutReady` (reading the shim's already-updated frame via `hostWindowFrame()`) so the new state commits already-hidden — no blink.

**Lesson**: For a transition with no host animation to mask timing, the geometry baseline must be a *settled* value (not a mid-layout capture), the discriminator must be transform-invariant (size, not origin), and the hide + the first overlay frame must land in the **same** runloop turn.

## 2026-06-01 — [Lifecycle] Arc-path ghost flights — RNS reparents our subtree (churn), it isn't a real unmount

**Symptom**: The arc-path back-flight landed too far left and fired multiple times (overlay count grew to 5); repeated tap→back eventually showed no flight.

**Root cause** (from logs): during a push every list hero goes `didMoveToWindow(nil)` → `didMoveToWindow(window)` with the **same** `ObjectIdentifier` within one runloop window — `react-native-screens` reparenting our subtree, not unmounting. That cleared `alreadyFlighted` (so the real unregister missed its guard and fired a bogus second flight) and triggered match-pass flights for the siblings; the transient re-attach also briefly exposed parallax-shifted `settledWindowFrame()` values.

**Fix**: Detect churn (`nil`→`window` for the same id in a tick) and **CHURN-CANCEL** the deferred unregister; split `unregister` into a deferred queue + `commitUnregister(key:)` (threading the original key so a config reset before commit can't mis-key); guard against same-view `source == dest` match-pass flights; key the recycle branch on `pending.key`.

**Lesson**: Treat the navigator as an adversary that detaches and reattaches the *same* view within a tick. Defer unregister one tick so a same-view re-register cancels it, and never key teardown on a config that may have been reset.

## 2026-06-01 — [Decision] Corner radius is read live from the view tree, never configured

**Context**: The basic example rounds its tiles — how is the radius for the morph chosen, and what if an app uses arbitrary radii?

**Decision**: Read the radius live at both ends via `effectiveCornerRadius()` (impl view → shim, where React's `borderRadius` actually lands → first child) and interpolate source→dest; never hardcode. Document that only **uniform** `layer.cornerRadius` is supported — per-corner radii animate as a single uniform value.

**Why**: Keeps the API prop-free and faithful to whatever the developer set, while being explicit about the uniform-radius limitation rather than silently mismatching corners.

**Lesson**: Derive visual params from the live view hierarchy instead of a prop, and state the primitive's limits (uniform-only) up front.

## 2026-05-27 — [Android] Flight "jumps/pauses" mid-flight — a `react-native-screens` FADE main-thread stall

**Symptom**: On Android the forward flight jumped (later: paused) ~40% through for BasicImageHero/Tabs/CardMorph, but SpringVsDuration was smooth and back-flights were fine.

**Root cause**: With `animation: 'fade'`, RNS's 150ms alpha finishes ~42% into a 360ms flight and fires `notifyViewAppearTransitionEnd()` + `endRemovalTransition()` — a JS event, a Fabric commit, and outgoing-fragment removal in one main-thread burst. The flight's per-frame `measureAndLayout` + `invalidateOutline()` competed for that same thread, blowing the VSYNC budget. SpringVsDuration uses DEFAULT (scale+alpha, 200ms), whose spike lands ~56% and is masked by the parallel scale.

**Fix**: Lay the overlay out **once** and animate via RenderNode `translationX/Y` + `scaleX/Y` (composited on the render thread, so a brief main-thread stall no longer skips flight frames); cap the per-frame delta in the Choreographer driver; and on Android fall back to the DEFAULT screen animation (keep FADE on iOS). Documented in `example/src/App.tsx`.

**Lesson**: Drive overlay motion with RenderNode transform properties, not per-frame layout, so it survives a main-thread stall — and know that the host navigator's own transition injects a predictable mid-flight spike you must design around.

## 2026-05-27 — [iOS/UIKit] White flash at flight start — a freshly-shown `UIWindow` needs a VSYNC to appear

**Symptom**: A white flash at the tapped image's position right as the flight started (and on back).

**Root cause**: In one runloop tick we hid the source, set the overlay `UIWindow.isHidden = false`, and added the flight view. But a previously-hidden `UIWindow` becoming visible can need an extra VSYNC before its contents render — for that frame the source was hidden with no overlay on screen, exposing the white ScrollView. Not an image-load/cache issue.

**Fix**: Keep the `OverlayHost` window resident (warmed at the first hero register) instead of toggling `isHidden` per flight, so the first overlay frame is on screen in the same tick. (Android uses the live `decorView.overlay`, so it never had this.)

**Lesson**: Don't toggle a `UIWindow`'s visibility on the hot path — a newly-visible window isn't guaranteed to paint the same frame. Keep the overlay surface alive.

## 2026-05-27 — [Android] `borderRadius`/`overflow` silently dropped by the Fabric codegen delegate

**Symptom**: Android tiles stayed square no matter the `borderRadius` style; an earlier "fix" hadn't worked.

**Root cause**: Fabric dispatches props via `ViewManager.getDelegate().setProperty`. The codegen delegate handles only the component's spec'd props (`heroId`, …) and falls through to `BaseViewManagerDelegate`, whose `setBorderRadius(T, Float)` overload resolves to a `BaseViewManager` no-op that just logs an unsupported-prop warning; `overflow` isn't matched at all.

**Fix**: Wrap the codegen delegate with `HeroStylePropDelegate` (returned from `getDelegate()`) that intercepts `borderRadius`/per-corner/`overflow`/`borderWidth`/`borderColor`/`borderStyle` and routes them through `BackgroundStyleApplicator`.

**Lesson**: A codegen-fronted Fabric view drops standard style props unless you explicitly re-wire them; the Paper-era `@ReactProp` setter is dead code under Fabric. (Don't remove `HeroStylePropDelegate`.)

## 2026-05-27 — [iOS/UIKit] Corner radius never animated — read from `contentView`, but React rounds the shim

**Symptom**: iOS removed the radius the instant a flight started (square overlay); Android (separately) kept it until the very end.

**Root cause**: React applies `borderRadius`/`overflow` to the Fabric shim (`RCTViewComponentView`), the **superview** of `_impl.contentView`. The flight engine read `contentView.layer.cornerRadius` (0) and the inner `<Image>` (0), so `initial.cornerRadius` was 0, the `if initial != end` guard skipped, and no `CABasicAnimation` was added. Android's separate bug: a hardware-layer cache froze the outline clip.

**Fix**: Read the radius from the shim chain (`effectiveCornerRadius()`); on Android stop promoting the snapshot to a hardware layer in snapshot mode so the per-frame outline interpolates.

**Lesson**: Know exactly which view in the shim/content hierarchy React applied a style to — reading geometry off the wrong layer silently yields zeros and disables the effect.

## 2026-05-27 — [Decision] Removed the `auxiliaryHidden` "hide every sibling hero" band-aid

**Context**: To stop other list heroes showing through during an iOS arc-path push, a flight briefly hid every *other* hero in the namespace (`auxiliaryHidden`), restoring them on completion.

**Decision**: Removed it on both platforms.

**Why**: In a vertical list it left captions (sibling `<Text>`, *outside* the hero) floating over blank gaps on push and back. The flying overlay already sits on a top-most layer and the natural screen transition handles focus; hiding siblings was heavy-handed and caused worse artifacts.

**Lesson**: Hide only the source and destination of the active flight. Don't suppress unrelated views to "focus" the overlay — it creates more visible breakage than it prevents. (Do not reintroduce it.)

## 2026-05-27 — [iOS/UIKit] Gray placeholder left at the source — the shim's own background kept drawing

**Symptom**: Tapping a hero left a gray rounded rectangle at its original spot during the flight.

**Root cause**: `setHiddenForFlight(true)` hid only `_impl.contentView`, but the shim (where React put `backgroundColor: '#eee'`, `borderRadius`, `overflow`) is the parent and kept painting its rounded background.

**Fix**: Hide the shim's visible chrome too when hiding for flight, so nothing is left behind at the source.

**Lesson**: "Hide the hero" must cover every layer React may have styled — the content wrapper *and* the shim — not just the child that holds the image.

## 2026-05-27 — [iOS/UIKit] First interactive-pop landing fix (`destFrameHint`) — later superseded

**Symptom**: Edge-swipe back flew to a position ~16pt left with the wrong width, then jumped to the right spot.

**Root cause**: On gesture start RNS re-attaches the previous screen, triggering an immediate `runTwinFlight(detail→list)`; `pollOnce`'s legacy "fire when two consecutive ticks match" caught a transient frame mid-Fabric-commit (off by the inner-container padding) before the layout converged.

**Fix (this stage)**: Threaded a `destFrameHint` (the previous flight's source frame) and fired only when `settledWindowFrame()` converged to the hint. This reduced but didn't eliminate the slow-swipe error.

**Lesson**: Convergence-to-a-hint beats a naive two-tick stability check during a navigator transition — but a time-driven flight still can't track a finger. This stage was later replaced by the gesture-driven `InteractiveStackPop` (see the 2026-06-08 entries above).

## 2026-05-27 — [Lifecycle] Fabric view-recycling hygiene (`prepareForRecycle` / `prepareToRecycleView`)

**Context**: Asked whether `prepareForReuse`-style cleanup was needed so a recycled view can't carry stale hero state.

**Decision**: iOS already resets in `SharedHeroViewImpl.prepareForRecycle()` (unregister, fresh `config`, clear `hiddenForFlight`/alpha/`stashedSnapshot`); added the Android counterpart — `resetHeroState()` invoked from `prepareToRecycleView` + `onDropViewInstance`.

**Why**: Fabric view recycling (opt-in on Android) reuses the same instance for a different hero; a stale `hiddenForFlight`/`stashedSnapshot`/`config` would corrupt the next mount.

**Lesson**: Any per-mount native state must be reset on the recycle hook on **both** platforms, even before recycling is enabled — cheap insurance against a class of "wrong/blank hero" bugs.

## 2026-05-26 — [iOS/UIKit] Back-flight landed too far left — `windowFrame()` reflected the parallax slide

**Symptom**: Popping arc-path, the hero flew back to a position too far left, then faded and the real thumbnail appeared at the correct spot.

**Root cause**: ArcPathDetail uses the default slide pop; the List re-attaches early with its container **translated** (parallax). Reading the destination via `convert(_:to:window)` returned the in-progress transitional x, so the flight landed at the parallax-start position.

**Fix**: Added `settledWindowFrame()` (iOS) / `settledWindowRect()` (Android) that walk the ancestor chain using untransformed model values (subtracting scroll offsets, ignoring `translationX/Y`/affine transforms). Destinations land on the settled frame; finger-tracked sources keep using the live `windowFrame()`.

**Lesson**: Destinations must land where the view *settles*, not where it is mid-transition. Maintain a transform-free "settled" frame distinct from the "live" frame and choose deliberately per use. (This split underpins many later fixes.)

## 2026-05-26 — [iOS/UIKit] The first real flight looked ugly — three fixes (cornerRadius, no-dest fade, soft handoff)

**Symptom**: The hero flattened its corners instantly, "disappeared" mid-flight, and the detail image popped in blank at the end.

**Root cause**: (1) `UIViewPropertyAnimator` doesn't animate `layer.cornerRadius` (the model jumps to the end value); (2) the default cross-fade faded the source to alpha 0 with no destination snapshot, so the flying view ended invisible; (3) the dest's remote `<Image>` hadn't loaded when the flight unhid it.

**Fix**: explicit `CABasicAnimation` for `cornerRadius` on the same timeline; skip the source fade when there's no dest counterpart; soft handoff — unhide the dest *behind* the still-visible flight view, then fade the flight view out over ~180ms (Android mirrors all three).

**Lesson**: Verify whether your animator actually animates each property (some are model-only), never fade a snapshot to nothing without a replacement, and end a flight with a crossfade so a not-yet-loaded destination degrades softly instead of popping.

## 2026-05-25 — [Lifecycle] Fire the flight on REGISTER when a live twin exists, not only on unregister

**Symptom**: The first builds did a normal nav slide with no transition, and the image flashed appear→blank→appear.

**Root cause**: The registry only started a flight when a hero **unregistered**. With native-stack push the source screen stays mounted through the slide, so the flight ran too late (after the swap).

**Fix**: When a second hero with the same `namespace::id` **registers** while a live twin exists, snapshot the existing twin immediately (before the navigator moves it) and flight twin→new view; keep the unregister path only for in-place toggles. Introduced `HeroSnapshot` + flight de-dup tracking.

**Lesson**: For a router-agnostic library, register/unregister (window attach) — not navigation events — are the only signals; the inbound match must trigger on register, capturing the source before any host animation perturbs it.

## 2026-05-25 — [DX] Bridging headers are unsupported on framework targets (`use_frameworks!`)

**Symptom**: iOS build failed with "Using bridging headers with framework targets is unsupported."

**Root cause**: The pod shipped a `SharedHero-Bridging-Header.h` + `SWIFT_OBJC_BRIDGING_HEADER`, incompatible with the framework target.

**Fix**: Deleted the (empty) bridging header and dropped `s.private_header_files` / `SWIFT_OBJC_BRIDGING_HEADER` from `SharedHero.podspec`; Obj-C++ → Swift bridging goes through `@objc`-exported Swift APIs via the auto-generated `SharedHero-Swift.h`, with `DEFINES_MODULE` + C++20 set.

**Lesson**: With `use_frameworks!`, bridge Obj-C++↔Swift via `@objc` + the generated `-Swift.h`, never a bridging header. (A separate `EventBeat.h 'atomic' file not found` build error was an unrelated RN-Fabric Pods toolchain issue resolved on the user's machine.)

## 2026-05-25 — [Decision] Build on the native view layer (UIKit / Android View) with a process-wide registry

**Context**: Greenfield choice between SwiftUI/Compose and UIKit/Android View, plus how to be navigation-agnostic given Reanimated SET's limits and `react-native-shared-element`'s maintenance status.

**Decision**: Implement a Fabric view component backed by UIKit (iOS) + Android View, with a process-wide native `HeroRegistry` keyed `namespace::id` and a window-level overlay; never import a navigation library.

**Why**: The native snapshot/overlay/transition APIs and the precise window/geometry control these transitions need live in UIKit/Android View; a registry driven by window attach is router-agnostic, where JS-coordinated approaches are stack- or feature-flag-bound.

**Lesson**: For a primitive meant to work under any router, anchor behavior to the platform view lifecycle, not to a navigator — it's the one signal every router shares.

---

## Cross-cutting principles
- **Think in windows and lifecycles first.** Before touching motion, answer: which window is each view in, and when does it register/unregister?
- **Overlay ⊇ destination window.** The flying overlay must never be occluded by the thing it's flying toward.
- **Gesture-driven, coordinator-synced** for anything interactive on iOS; never time-driven.
- **Delete superseded patches** the moment the real mechanism lands.
- **Default-on, single-site** for any toggle that could ripple across paths.
- **Snapshots must never be blank.** Capture the source while it's attached and painted; keep a rolling stash plus a per-key last-known-good so a flight never flies an invisible bitmap.
- **Match destinations to the settled frame, sources to the live frame.** The two diverge exactly during the transitions you care about.
- **The host navigator churns, parallaxes, and stalls.** Defer-unregister to absorb same-tick reparenting, read transform-free frames for landings, and composite the overlay on the render thread.
- **Compile against the RN floor, not the example's RN.** We ship source; a native API must exist on every supported RN. The example masks recently-added/removed APIs — pick the widest-compatible overload and verify against the minimum version before publishing.
