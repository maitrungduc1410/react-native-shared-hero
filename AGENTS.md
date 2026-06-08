# AGENTS.md

Guidance for AI coding agents and contributors working in this repo. Keep changes accurate to the native code — most behaviour lives in Swift/Kotlin, not JS. For the full design rationale, read [ARCHITECTURE.md](./ARCHITECTURE.md). Before changing the flight/registry/overlay logic, skim [LESSONS_LEARNED.md](./LESSONS_LEARNED.md) — it records the hard-won bugs and the rules that prevent re-introducing them (and add an entry when you hit a new non-obvious one).

## What this is

`react-native-shared-hero` is a **Fabric (New Architecture) view component** that performs native shared-element ("hero") transitions. A `<SharedHero id="..." namespace="...">` registers itself with a process-wide native registry on mount and unregisters on unmount; when a matching twin appears or disappears, the registry captures a snapshot and runs a flight in a window-level overlay. It is **router-agnostic** — it never imports a navigation library. The example app uses `@react-navigation/native-stack` + `react-native-screens` only to exercise it.

## Repo layout

- `src/` — the JS/TS public surface.
  - `index.tsx` — exports `SharedHero` (alias of `SharedHeroView`), `useSharedHero`, and the public types.
  - `SharedHeroView.tsx` — the React component; maps friendly props (`id`, `namespace`, `spring`, …) onto the codegen native props (`heroId`, `heroNamespace`, `springDamping`, …) and adapts the native events.
  - `SharedHeroViewNativeComponent.ts` — the Fabric `codegenNativeComponent` spec (`NativeProps`, direct event handlers). This drives codegen.
  - `types.ts` — `SharedHeroProps` and the enums. Source of truth for the public API.
  - `useSharedHero.ts` — JS-only state helper for in-place toggles (no native calls).
- `ios/` — Swift + Obj-C++ implementation (see ARCHITECTURE.md for each file).
  - `SharedHeroView.h/.mm` (Fabric `RCTViewComponentView` shim), `SharedHeroViewImpl.swift` (per-view behaviour + snapshot/geometry), `HeroRegistry.swift` (matching + flight scheduling), `FlightEngine.swift` (the animation), `OverlayHost.swift` (the overlay `UIWindow`), `InteractiveStackPop.swift` + `InteractiveModalReturn.swift` (interactive returns), `SystemZoomBridge.swift` (v2 stub).
- `android/src/main/java/com/sharedhero/` — Kotlin implementation.
  - `SharedHeroView.kt` (the `ReactViewGroup`), `SharedHeroViewManager.kt` (Fabric view manager + style-prop interceptor), `HeroRegistry.kt`, `FlightEngine.kt`, `OverlayHost.kt`, `HeroSnapshot.kt`.
- `example/` — the demo app (Yarn workspace), one screen per use case under `example/src/screens/**`, wired in `example/src/App.tsx` / `navigation.ts`.

## New Architecture / codegen

- The component is Fabric-only. `codegenConfig` in `package.json` declares the spec `SharedHeroViewSpec` with `jsSrcsDir: "src"`, Android package `com.sharedhero`, and the iOS component `SharedHeroView` → class `SharedHeroView`.
- Native prop names are the codegen names (`heroId`, `heroNamespace`, `mode`, `duration`, `springDamping/Stiffness/Mass`, `fadeMode`, `easing`, `motionPath`, `enabled`, `returnFlightEnabled`) plus `onTransitionStart`/`onTransitionEnd` direct events carrying `{ id, ns }`. If you add a prop, update **all** of: `types.ts`, `SharedHeroView.tsx`, `SharedHeroViewNativeComponent.ts`, the iOS `updateProps` in `SharedHeroView.mm` + `SharedHeroConfig`, and the Android `@ReactProp` setter + `SharedHeroConfig`.
- Android style props (`borderRadius`, `overflow`, `borderWidth/Color/Style`) are intercepted by `HeroStylePropDelegate` and routed through `BackgroundStyleApplicator` — codegen-fronted components otherwise drop them. Don't remove that delegate.

## Build / test / lint

Root `package.json` scripts:

- `yarn typecheck` → `tsc` (type-checks the library).
- `yarn lint` → `eslint "**/*.{js,ts,tsx}"`.
- `yarn prepare` → `bob build` (builds `lib/` via react-native-builder-bob; ESM + TypeScript defs).
- `yarn clean` → removes build outputs.

Example app (run from repo root; it's a workspace):

- `yarn example start` — Metro.
- `yarn example ios` / `yarn example android` — build + run.
- Type-check the example separately: `npx tsc --noEmit -p example/tsconfig.json`.

Important: **native changes (Swift/Kotlin) cannot be validated by a JS reload.** You must rebuild through Xcode / Gradle (or `yarn example ios` / `yarn example android`) for `ios/` or `android/` edits to take effect. A Metro Fast Refresh only re-runs JS.

There is no automated test suite; verification is by running the example and watching the flights (the native code logs heavily via `NSLog`/`Log.d` with tags like `SharedHeroRegistry`, `SharedHeroFlight`, `SharedHeroStackPop`).

## Key invariants — do not break

- **Registration rides the window lifecycle.** iOS registers/unregisters from `didMoveToWindow`/`willMoveToWindow` (plus prop changes in `didUpdateConfig`); Android from `onAttachedToWindow`/`onDetachedFromWindow`. The matching model assumes register/unregister are driven by window attach, not by navigation events.
- **Matching key is `namespace::id`.** Both platforms compute `"${namespace}::${id}"`. Don't change the separator or the keying without updating both registries and all the per-key caches.
- **Unregister is deferred one tick (iOS) for churn cancellation.** `react-native-screens` reparents a screen's subtree on every push (detach→reattach the *same* view within a tick). iOS defers the unregister commit so a same-view re-register cancels it. Don't make unregister synchronous; don't fire flights from a view onto itself (the `sourceViewId == dest` "same-id churn" guard exists for this).
- **The overlay host must net to zero.** Each flight does exactly one `OverlayHost.host()` ↔ one `releaseHost()`. The interactive controllers retain the host **once per session** and release it once after the last pair finishes. If you add a flight path, balance the ref-count.
- **Interactive returns own their transitions.** On iOS, the left-edge swipe-back pop is owned by `InteractiveStackPop` and the sheet swipe-down dismiss by `InteractiveModalReturn`. When they adopt a transition they mark the hero `interactivelyHandled` (reusing the registry's `alreadyFlighted` set) so the registry's time-driven back-flight **stands down**. Don't make the registry fire a competing flight for those cases.
- **`windowFrame()` vs `settledWindowFrame()` (iOS) / `windowRect()` vs `settledWindowRect()` (Android).** The "live" frame reflects in-progress ancestor transforms (parallax, drag); the "settled" frame is transform-free (where the view lands once the transition finishes). Destinations land on the settled frame; finger-tracked sources use the live frame. Keep that distinction.
- **Snapshots must be non-blank.** Both platforms stash the last good render so a flight never flies an invisible bitmap (remote `<Image>` paints a few frames after mount; detaching views release their drawable). On Android the rolling `dispatchDraw` capture + `isLikelyBlankBitmap` heuristic exist for the cold-launch case; don't strip them.
- **Do not reintroduce removed band-aids.** Earlier iterations had hacks like `isBackFlight`, `handoffHold`, and an `auxiliaryHidden` that hid sibling heroes during a flight. They caused regressions (siblings disappearing, double flights) and were deliberately removed. The current model is: hide only the source + destination of the active flight, use the registry caches/poll for layout-settle, and let the interactive controllers own gestures.
- **`returnFlightEnabled` only affects the unregister/back-flight path.** A `false` hero does a quiet teardown (no return flight). The inbound flight is unaffected.

## Conventions

- Comments explain **non-obvious intent, trade-offs, and the bug a piece of code prevents** — not what the code literally does. The native files are heavily commented in this style; match it. Don't add narration comments.
- Keep the JS surface minimal and typed; the heavy lifting is native.
- `zoom`/`auto` modes are intentionally aliased to `morph` in v1 (`SystemZoomBridge` is a stub for the iOS 18+ system zoom). `shuttle` aliases `snapshot`. Don't claim these are implemented.
