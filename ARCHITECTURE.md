# Architecture

How `react-native-shared-hero` works under the hood. This is the detailed companion to the [README](./README.md); read that first for the API and use cases.

The library is deliberately **router-agnostic**. There is no integration with any navigation library, no transition delegate to register, no `<SharedElement>` wrapper that needs to know about screens. Instead every `<SharedHero>` is a Fabric view that **registers with a process-wide native registry** when it attaches to a window and **unregisters** when it leaves. The registry matches a source and destination by `namespace::id`, captures a bitmap snapshot of the source, and animates that snapshot in a **window-level overlay** that sits above every presentation context. The same mechanism therefore covers native-stack push/pop, modals, transparent modals, sheets, tab swaps, virtualized lists, multi-step chains, and plain in-place state toggles — because they all reduce to "a hero with id X disappeared and a hero with id X appeared".

## High-level model

```
   <SharedHero id="x" ns="g">                 <SharedHero id="x" ns="g">
   on screen A (source)                       on screen B (destination)
            │                                            │
            │ attach → register("g::x")                  │ attach → register("g::x")
            ▼                                            ▼
   ┌─────────────────────────── HeroRegistry ───────────────────────────┐
   │  live: { "g::x": [WeakRef(A), WeakRef(B)] }                          │
   │  on twin match → capture snapshot of source, schedule a flight       │
   └──────────────────────────────────┬──────────────────────────────────┘
                                       ▼
                              ┌──────────────────┐
                              │   FlightEngine    │  translate + scale + crossfade
                              │  (linear/arc/     │  (+ corner radius & bg for morph)
                              │   spring)         │
                              └────────┬──────────┘
                                       ▼
                       ┌───────────────────────────────┐
                       │ OverlayHost                    │
                       │  iOS:  UIWindow @ alert+1       │  above modals/sheets
                       │  Android: ViewGroupOverlay of   │  resolved from the dest
                       │           the dest's window     │  view's own window
                       └───────────────────────────────┘
```

**Triggers.** There are two ways a flight starts:

1. **Twin appears while another is still live** (native-stack push and pop — both screens' hero views are attached during the navigator's animation). The registry captures the existing twin's snapshot the moment the new twin registers, *before* the navigator starts moving anything, then schedules the flight for when the destination has been laid out.
2. **A twin unregisters, then a new one mounts within ~1 tick** (in-place state toggles, and cross-window reappearance like a core `<Modal>` dismiss). The unregistered hero is parked briefly as a source candidate; a "match pass" on the next runloop tick pairs it with the freshly mounted destination.

**Modes** (`mode` prop): `snapshot` (clone + translate/scale/crossfade), `morph` (also interpolates corner radius and background color — Material container transform). `shuttle` aliases `snapshot`, and `zoom`/`auto` alias `morph` in v1 (the iOS 18 system-zoom hook is stubbed). **Motion** (`motionPath`): `linear` or a quadratic-bezier `arc`. **Timing**: time-based with an easing preset, or spring when `spring.stiffness` and `spring.mass` are non-zero.

## The JS / Fabric layer

The public component is tiny. `src/SharedHeroView.tsx` takes the friendly props and forwards them to the codegen native component, splitting `spring` into three scalar props and adapting the native `{ id, ns }` event payload into `{ id, namespace }`:

```tsx
<NativeSharedHero
  {...rest}
  heroId={id}
  heroNamespace={namespace}
  mode={mode}
  duration={duration}
  springDamping={spring?.damping}
  springStiffness={spring?.stiffness}
  springMass={spring?.mass}
  fadeMode={fadeMode}
  easing={easing}
  motionPath={motionPath}
  enabled={enabled}
  returnFlightEnabled={returnFlightEnabled}
  onTransitionStart={startHandler}
  onTransitionEnd={endHandler}
>
  {children}
</NativeSharedHero>
```

`src/SharedHeroViewNativeComponent.ts` is the `codegenNativeComponent<NativeProps>('SharedHeroView')` spec: it declares `heroId`, `heroNamespace`, `mode`, `duration`, `springDamping/Stiffness/Mass`, `fadeMode`, `easing`, `motionPath`, `enabled`, `returnFlightEnabled`, and the two `DirectEventHandler` events. Codegen turns this into the Fabric props struct (`SharedHeroViewProps`) and event emitters used by the native shims. `useSharedHero` is JS-only sugar: it toggles React state so you render two same-id subtrees; it never calls native.

## iOS implementation

### The Fabric shim — `SharedHeroView.h/.mm`

`SharedHeroView` is an `RCTViewComponentView`. It owns a `SharedHeroViewImpl` (the Swift companion) and routes the important lifecycle into it:

- `initWithFrame:` creates the impl, pins `impl.contentView` as the component's `contentView`, and wires `onTransitionStart`/`onTransitionEnd` to emit Fabric direct events.
- **Children are mounted into `impl.contentView`**, not into `self`. This is essential: `setHiddenForFlight` toggles `contentView`'s visibility and `captureSnapshot` renders `contentView`, so the React children must actually live there.
- `willMoveToWindow:` (→ `prepareToLeaveWindow`) stashes a snapshot while the view is still on-window. `didMoveToWindow` (→ `didMoveToWindow:`) registers/unregisters. `updateLayoutMetrics:` (→ `didUpdateLayoutMetrics`) feeds the layout-settle machinery. `updateProps:` copies props into `SharedHeroConfig` and calls `didUpdateConfig`. `prepareForRecycle` resets state.

### `SharedHeroViewImpl.swift` — per-view behaviour

Holds the `SharedHeroConfig` (the resolved props, with native defaults: `duration = 320`, `mode = "snapshot"`, etc.) and all the snapshot/geometry logic.

- **Registration.** `didUpdateConfig` registers when `enabled && !heroId.isEmpty`, re-registers if `namespace::id` changed, and unregisters when disabled. `didMoveToWindow(_:)` registers on attach and unregisters on detach — and deliberately does **not** wipe the stash on re-attach (a forward flight can ask for a snapshot before Fabric commits the first layout; keeping the last good one prevents a "fade with no hero").
- **Snapshot capture.** `captureSnapshotRaw()` renders `contentView` via `drawHierarchy(in:afterScreenUpdates:false)` into a `HeroSnapshot` (image + window frame + settled frame + corner radius + background color), and refreshes a `stashedSnapshot`. `captureSnapshot()` prefers the stash when the view is currently hidden for a flight (a hidden view renders empty pixels), then a fresh render, then the stash as a fallback. `prepareToLeaveWindow()` captures the stash before the host navigator detaches the view.
- **`windowFrame()` vs `settledWindowFrame()`.** `windowFrame()` is `convert(bounds, to: window)` and therefore reflects any in-progress ancestor transforms (the parallax slide of a push/pop, a drag offset). `settledWindowFrame()` answers "where will this land once the transition finishes": it walks the **layer** superchain (not the view chain — UIKit inserts free-standing `CALayer`s, e.g. the `UITransitionView`'s, that the view chain skips), snaps every non-identity transform to identity inside a no-action `CATransaction`, reads `convert(bounds, to: window)`, then restores the transforms — all in one tick so the screen never renders the reset state. Destinations use the settled frame; finger-tracked sources use the live frame.
- **`effectiveCornerRadius()` / `effectiveBackgroundColor()`.** React applies `borderRadius`/`backgroundColor` to the **shim** (`contentView.superview`), not `contentView`. These helpers resolve the radius/color from `contentView`, then the shim, then the first child — so a `morph` flight matches the visible rounding instead of snapping to square at t=0.
- **`setHiddenForFlight(_:)`.** Hides both `contentView` and the shim (the shim carries the `#eee`/rounded background; hiding only `contentView` left a "gray rounded rectangle at the source"). Caches a clean snapshot before hiding, and restores the saved shim alpha on reveal.
- **In-place support.** `recordStableFrameSoon()` records the last stable on-window frame from layout metrics (a live capture mid-toggle is torn — new origin, old size). `inPlaceBaselineSnapshot()` pairs the most recent bitmap with that stable geometry.

### `HeroRegistry.swift` — matching and scheduling

A main-thread singleton. State worth knowing:

- `live: [String: [WeakBox]]` — currently-mounted heroes per `namespace::id` (weak, never pins views).
- `recentlyUnregistered` — source candidates parked for one tick, each tagged with the source view's `ObjectIdentifier` so the match pass can reject "the dest is the same instance that just unregistered" (host-navigator reparent churn → would fly a view onto itself = a ghost snapshot).
- `pendingUnregisters` — **the churn-cancel mechanism.** `unregister(_:)` does not act immediately; it stashes the view + key + a captured baseline and defers the real work to the next runloop tick. `react-native-screens` reparents a screen's whole subtree on every push (detach→reattach the *same* `SharedHeroViewImpl` within a tick); when `register` sees that same view+key come back, it pulls the entry out and the unregister becomes a no-op (with a `pendingInPlace` watch if the size actually changes — that's how an in-place toggle is distinguished from a reparent: SIZE change, never just position, because a push parallax-shifts a sibling's origin).
- `alreadyFlighted` — views that were the source of a recent flight, so their later unregister doesn't fire a duplicate. **Reused by the interactive controllers** via `markInteractivelyHandled`/`unmarkInteractivelyHandled` to make the registry stand down.
- `lastKnownSnapshots` — per-key source-side bitmap fallback (covers the source view being recycled between two pushes).
- `lastFlightSourceFrame` — per-key cache of the previous flight's source frame, exploited as the **`destFrameHint`** for the next flight: push and pop swap source/dest roles, so the previous source frame is exactly where the current destination should land. This is what lets the poll loop reject a transiently-wrong layout and wait for the real one.
- `currentlyFlying` — destinations with an active flight, to suppress duplicate triggers.

Flow:

- `register` pre-warms the overlay window, runs the churn-cancel/key-changed branches, clears stale per-id state (Fabric reuses `ObjectIdentifier`s), then looks for a still-attached twin. If one exists → `runTwinFlight`. Otherwise, if a source for this key is parked in `recentlyUnregistered` (a separate-window reappearance), it hides the just-attached cell immediately and schedules a match pass.
- `runTwinFlight(source:dest:)` resolves the source snapshot (live → registry cache → abort), rebuilds it at the **settled** source frame so an in-progress push parallax doesn't make the overlay start at a left-shifted position, records the symmetric hint, and — crucially — calls `InteractiveStackPop.tryAdoptInteractivePop(...)`. If that returns true (a real interactive edge-swipe), the time-driven flight is **skipped** and the controller owns the return. Otherwise it hides the destination, queues the flight, and arms both interactive controllers.
- `commitUnregister` (deferred) handles the back-flight: it honours `returnFlightEnabled` (a `false` hero teardown is quiet), prefers an attached twin else an off-window twin (the modal-dismiss case), suppresses the flight when the source snapshot is below the screen bottom (an interactive sheet swipe already revealed the list cleanly), and otherwise queues a back-flight.
- `queuePendingFlight` + `pollOnce` — the layout-settle loop. It polls once per runloop tick and fires when either the freshly-sampled `settled` frame matches the cached `destFrameHint` within tolerance (the strong path), or — for a first-ever/back-flight with no hint — two consecutive ticks read the same non-zero settled frame. It tolerates a destination that hasn't attached yet (a UIKit modal keeps presented content off-window during the present animation) by waiting on a wall-clock `attachDeadline` without burning the layout-attempt budget. `notifyLayoutReady` is the synchronous fast path for in-place resizes (fires in the same layout transaction, so the new state never renders uncovered). `runMatchPass` handles the unregister→register pairing, with a synchronous fast path for instant modal dismiss.

### `FlightEngine.swift` — the animation

`run(from:sourceView:to:destFrameOverride:onAllDone:)` builds a `flightView` (a `UIView` with the source bitmap as an aspect-fill `UIImageView`), adds it to the overlay, hides the destination, then animates frame (and, for morph, corner radius via an explicit `CABasicAnimation` because `UIViewPropertyAnimator` doesn't animate `cornerRadius`, plus background color). Timing is either a `UIViewPropertyAnimator` (time + easing curve) or `UISpringTimingParameters` (when `usesSpring`). The `arc` path uses a `CADisplayLink` driver and a quadratic bezier through a control point at the corner of the source/dest rectangle. A **soft handoff** ends every flight: reveal the real destination under the overlay, fade the overlay out over ~0.18s, then un-hide the source (off-screen by now) and release the overlay host. `fadeMode` controls the source/dest alpha curves (`cross`/`in`/`out`/`through`).

### `OverlayHost.swift` — the overlay window

A library-owned `UIWindow` at `windowLevel = .alert + 1`, transparent and non-interactive (touches fall through via a `PassThroughView`). It is created lazily on the first hero registration (`prepare()`) and **stays visible forever after** — toggling `isHidden` per flight caused a one-frame white flash. A `OverlayRootViewController` defers all status-bar/rotation preferences to the underlying app's topmost view controller so the always-on overlay doesn't hijack system chrome. `host()`/`releaseHost()` maintain an `activeFlightCount` (the window itself never hides); the count must net to zero.

### `InteractiveStackPop.swift` — the iOS left-edge swipe-back

The registry's back-flight is queued from `commitUnregister`, i.e. only when the detail screen *unmounts* — which React-Navigation does at the **end** of a pop. A fixed-duration flight starting then can never track the finger, and on a normal-speed swipe the re-entering list is still parallax-sliding, so the landing target is a moving goalpost. UIKit's interactive transition can't be hooked (RNS owns the nav controller), so this controller **observes** the motion and drives its own overlay:

- Armed at push time on the freshly-pushed detail hero (`arm`). It runs a `CADisplayLink`, waits for the push to settle, and confirms it's inside a popable `UINavigationController` (sheets are excluded — those belong to `InteractiveModalReturn`).
- On the back swipe, `runTwinFlight` calls `tryAdoptInteractivePop`, which checks the host nav controller's `transitionCoordinator` for `isInteractive`/`initiallyInteractive`. If so it adopts the (detail → re-entering list) pair, marks the list hero `interactivelyHandled`, hides it, and returns `true` so the registry skips its flight.
- **Multiple pairs.** A single popping screen can carry more than one hero (e.g. MultiStep's big hero + "Up next" thumbnail). Each twin pair fires its own `runTwinFlight`, so the controller tracks a **set of `TrackedPair`s**, each with its own overlay/snapshot/source rect, all advanced together by one `tick()` driven by a single armed "driver" hero.
- Each frame the overlay is lerped between the finger-following source (`sourceRect` offset by the live translation) and the list thumbnail's **live** (parallax-sliding) window frame, so overlay and real re-entering list stay locked — no veer.
- **Release is synced to UIKit.** On finger lift `windowFrame()` jumps to the model's final value, so the controller stops finger-tracking and runs `beginSyncedFinish` using the transition coordinator's `transitionDuration` + `completionCurve` — flying each overlay onto the list cell (commit) or back to the detail (cancel) in lock-step with the page. A very fast swipe that committed before the activation threshold is handled by synthesizing overlays and running the same commit. A fallback `committing`/`driveCommit` path (no coordinator) glues overlays to the live thumbnails until the slide converges, then crossfades.

### `InteractiveModalReturn.swift` — the sheet swipe-down dismiss

Same strategy on the vertical axis for `pageSheet`/`formSheet` modals. A button dismiss works through the normal back-flight (React-Navigation unmounts at the *start*), but a swipe dismiss only unmounts *after* the sheet finishes — too late. The controller arms at push time, waits for the present to settle, confirms `isInSheet`, then on a downward drag captures the source, hides the hero + list thumbnail, and each frame lerps an overlay from the finger-following position toward the thumbnail's `settledWindowFrame()` (the presenter is scaled/recessed under a sheet, so the live frame is distorted). On commit it lands on the thumbnail and crossfades; on cancel it restores. It marks the hero `interactivelyHandled` so the registry stands down.

### `SystemZoomBridge.swift` — v2 stub

The hook point for iOS 18's `UIViewController.preferredTransition = .zoom(...)`. Wiring that requires setting `preferredTransition` on the destination *before* push, which ties the model to the host navigator's lifecycle — deliberately avoided in v1. So `zoom`/`auto` alias `morph` and `tryInstallSystemZoom` always returns `false` today.

## Android implementation

The structure mirrors iOS, adapted to the View system.

### `SharedHeroView.kt` — the `ReactViewGroup`

Extends `ReactViewGroup` (not plain `ViewGroup`) so standard RN style props flow through `BackgroundStyleApplicator`.

- **Lifecycle.** `onAttachedToWindow` clears the stale stash and registers; `onDetachedFromWindow` sets a `detaching` flag **before** unregistering (a `ViewGroup` detaches children first, and `<Image>`/Fresco releases its drawable on detach, so a live render here would be blank) and unregisters. `onSizeChanged` calls `HeroRegistry.notifyLayoutReady`.
- **Rolling snapshot.** `dispatchDraw` captures a throttled, always-fresh stash whenever the view actually redraws (notably when a remote `<Image>` fades in). Until a verified non-blank stash exists the throttle is skipped — the cold-launch fix, since the image paints a few frames after first layout and that draw is often the only one. `isLikelyBlankBitmap` (sampling a few centre pixels) gates promotion to the stash. `setHiddenForFlight` captures before hiding and, on reveal, `refreshStashSoon()` forces a couple of captures (a flight destination is hidden its whole formative life, so `dispatchDraw` never captured it — without this the next toggle's source is blank).
- **Geometry.** `windowRect()` = `getLocationInWindow` (live, includes transforms). `settledWindowRect()` walks the parent chain using each view's layout-time `left/top` minus the parent's `scrollX/Y`, so it excludes `translationX/Y`/matrix transforms — the landing rect mid-transition.
- **Unclipped capture.** `captureSnapshotRaw` renders children **without** the rounded `overflow: hidden` clip (via `drawContentUnclipped`). A source captured with baked rounding, scaled up to the destination, would look rounder than the destination and "pop" at handoff; capturing square and letting the overlay own the (interpolated) rounding avoids that — mirroring iOS.
- `cornerRadiusPx` / `backgroundColorInt` are mirrored from the manager's prop setters so the flight engine can read them back.

### `SharedHeroViewManager.kt` — view manager + style interceptor

Extends `ReactClippingViewManager` and wraps the codegen delegate in **`HeroStylePropDelegate`**. This is load-bearing: a codegen-fronted Fabric component routes `borderRadius` to `BaseViewManager`'s deprecated no-op Float overload and drops `overflow`/`borderWidth`/`borderColor`/`borderStyle` entirely. The delegate intercepts those prop names (uniform + every per-corner/per-side variant) and applies them through `BackgroundStyleApplicator` the way stock `ReactViewManager` does, mirroring the all-corners radius onto `cornerRadiusPx`. `prepareToRecycleView`/`onDropViewInstance` defensively reset hero state.

### `HeroRegistry.kt`

The same two-trigger model as iOS, keyed by `System.identityHashCode` and `namespace::id`. `register` clears stale per-id state, finds an attached twin (→ `runTwinFlight`), or handles a same-tick in-place match **synchronously** (Android processes Remove before Insert and does not recycle our view, so an in-place toggle mounts a brand-new destination; firing synchronously from `notifyLayoutReady` hides it before its first draw — no hard snap, no blank). `unregister` honours `returnFlightEnabled`, fires an attached-twin back-flight immediately, else parks the source for the match pass. `lastKnownSnapshots` + `resolveInPlaceSource` provide the non-blank fallback. `queuePendingFlight`/`tryFire`/`pollForLayout` are the layout-settle loop; in-place flights fire synchronously on layout-ready while navigation flights defer a frame. There's a bounded `CONTENT_WAIT_ATTEMPTS` wait for a cold-launch `<Image>` to paint before firing best-effort.

### `FlightEngine.kt`

Builds a `FrameLayout` container holding the source bitmap in a `ScaleType.MATRIX` `ImageView` (the matrix is recomputed each frame for continuous aspect-fill center-crop, matching iOS `.scaleAspectFill`). Corner rounding uses `clipToOutline` + a per-frame `ViewOutlineProvider` round rect (an attempted `saveLayer`/`DST_IN` mask regressed to square corners on the GPU canvas; the View is intentionally **not** promoted to a hardware layer so per-frame radius updates aren't frozen). Per-frame movement uses `translationX/Y` + `scaleX/Y` on the RenderNode (no re-measure/layout), with the container laid out once at the destination size via `measureAndLayout`. Timing: `runLinearFlight`, `runArcFlight` (quadratic bezier), or `runSpringFlight` (`SpringAnimation` over normalized 0..1 progress, with `MIN_VISIBLE_CHANGE_SCALE` so the spring runs its full underdamped course). A **custom Choreographer animator** (`runFlight`) caps the per-frame delta to `MAX_FRAME_DT_MS` so a main-thread stall during an RNS fragment transition lengthens the flight instead of teleporting it to the end. The soft handoff reveals the dest, fades the container out, then un-hides the source.

### `OverlayHost.kt`

Resolves a `ViewGroupOverlay` from the **destination view's own window** (`view.rootView.overlay`), falling back to the Activity decor's overlay. For same-window flights this is the Activity decor (unchanged). For a core `<Modal>` forward open, the destination lives in the Modal's **separate `Dialog` window**, so the flight is hosted in the Dialog decor — *above* the modal content — instead of behind it. `ViewGroupOverlay` (not `View.overlay`) is required because it accepts `View` children, not just drawables.

### `HeroSnapshot.kt`

The immutable `(bitmap, rect, cornerRadius, backgroundColor)` capture, plus `isLikelyBlankBitmap` — the cheap centre-sample heuristic that everything uses to avoid flying a transparent overlay (the cold-launch and detaching-`<Image>` cases).

## Navigation / react-native-screens interop

The library is router-agnostic by construction: it never references a navigation API. It works *with* `react-native-screens` because it rides the **window attach/detach lifecycle** that RNS drives on its native screen views (`RNSScreen*`). When RNS pushes a screen, both the outgoing and incoming `SharedHeroViewImpl`s are on-window during the slide, so the twin-on-register path fires; when it pops, the re-entering screen re-registers and the back-flight (or the interactive controller) takes over.

Two RNS behaviours shape the design:

- **Reparent churn.** On every push RNS moves the from-screen into a transition container, which detaches and reattaches our subtree (the same view instance) within a tick. The iOS deferred-unregister / churn-cancel machinery and both platforms' same-id-churn guard exist specifically so this reparent is **not** mistaken for a real unmount (which would spawn ghost flights).
- **Parallax.** RNS animates the previous/next screen with a translation transform. The `settled*Frame`/`settled*Rect` helpers strip that transform so flights land at the natural position rather than the transient parallax-shifted one.

**Separate windows.** Native-stack modals/sheets are separate UIKit presentations (and on Android the native-stack sheet style), and React Native's core `<Modal>` is an entirely separate window (`RCTModalHostView` / a `Dialog`). The window-level overlay is what makes flights cross those boundaries: on iOS the overlay `UIWindow` sits at `.alert + 1` above any presented modal; on Android the overlay is resolved from the destination view's own window so a Dialog-hosted destination gets its overlay in the Dialog decor. The iOS interactive controllers coordinate with — but never depend on — the navigator by reading the host `UINavigationController.transitionCoordinator` to sync their overlay animation to the real push/pop or sheet dismiss.

---

See the [README](./README.md) for the API reference and runnable examples, and [LESSONS_LEARNED.md](./LESSONS_LEARNED.md) for the bugs and design decisions that shaped the design described above — especially the cross-window (core `<Modal>` / Dialog) and interactive-pop sagas.
