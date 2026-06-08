
# react-native-shared-hero

High-performance, fully-native shared-element ("hero") transitions for React Native. Every flight runs in **Swift and Kotlin** on the **New Architecture (Fabric)** — no JS-thread animation — and the library is **router-agnostic**: it matches a source and destination by id across mount/unmount and flies a snapshot in a window-level overlay, with no dependency on any navigation library. Works in bare React Native and **Expo** apps (via a [development build](#use-with-expo)).

> How it works under the hood — see [ARCHITECTURE.md](./ARCHITECTURE.md).

## Showcase

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/35170436-3921-43ad-ac1c-face5a00c7ec" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/3aee83c7-190e-41fa-87b2-9a8ada59a481" controls loop muted></video> |

## Table of contents

- [Features](#features)
- [Why this library?](#why-this-library)
- [Requirements](#requirements)
- [Installation](#installation)
  - [Use with Expo](#use-with-expo)
- [Quick start](#quick-start)
- [API reference](#api-reference)
  - [`useSharedHero`](#usesharedhero)
- [Use cases](#use-cases)
  - [Basic image hero](#basic-image-hero)
  - [FlatList (virtualized)](#flatlist-virtualized)
  - [Card morph (Material container)](#card-morph-material-container)
  - [Native modal hero](#native-modal-hero)
  - [Transparent modal hero](#transparent-modal-hero)
  - [Tabs → detail hero](#tabs--detail-hero)
  - [FormSheet hero](#formsheet-hero)
  - [In-place toggle](#in-place-toggle)
  - [Spring vs duration](#spring-vs-duration)
  - [Arc path motion](#arc-path-motion)
  - [Custom shuttle](#custom-shuttle)
  - [Drag-to-dismiss (gesture return)](#drag-to-dismiss-gesture-return)
  - [Multi-step navigation](#multi-step-navigation)
  - [Core Modal (React Native)](#core-modal-react-native)
- [Example app](#example-app)
- [Under the hood](#under-the-hood)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Fully native** flight engine in Swift and Kotlin on the New Architecture (Fabric) — no JS-thread animation and no Paper/legacy fallback.
- **Router-agnostic** by design: matches elements by `id` (keyed `namespace::id`), so it never imports or depends on a navigation library.
- **Works everywhere a screen can change**: native-stack push/pop, native modals, transparent modals, form sheets, in-screen tabs, virtualized `FlatList`s, multi-step navigation chains, and plain in-place `useState` toggles.
- **Window-level overlay** so the flying element renders above modals, transparent modals, sheets, and even React Native's core `<Modal>` (a separate window).
- **Two transition styles**: `snapshot` (clone, translate + scale + crossfade) and `morph` (Material container transform that also interpolates corner radius and background color).
- **Rounded-corner and frame morphing** — bounds, corner radius, and background color animate together in `morph` mode.
- **Spring or duration timing**: a physical spring config or a time-based curve with easing presets (`standard`, `emphasized`, and the usual ease in/out).
- **Linear or arc motion paths** for the flying element's centre, plus configurable `fadeMode` (`cross`, `in`, `out`, `through`).
- **Interactive gesture returns on iOS**: the left-edge swipe-back pop and the sheet swipe-down dismiss are tracked frame-by-frame and synced through the host navigator's transition coordinator.
- **Per-element opt-outs**: `enabled` disables participation without unmounting, and `returnFlightEnabled` suppresses a redundant back-flight when the dismissal already carries the element away.
- **In-place transitions** via the JS-only [`useSharedHero`](#usesharedhero) helper — toggle two subtrees with the same `id` and the unmount→mount match flies automatically.
- **Transition callbacks**: `onTransitionStart` / `onTransitionEnd` fire on the source and destination views.

## Why this library?

The established options — [`react-native-shared-element`](https://github.com/IjzerenHein/react-native-shared-element) (low-level native "primitives") and its [`react-navigation-shared-element`](https://github.com/IjzerenHein/react-navigation-shared-element) binding — pioneered native shared-element transitions in React Native and are still great references. But both are now **explicitly looking for a new maintainer**, predate the **New Architecture**, and the navigation binding only ever supported the **JS Stack** (its Native Stack support was never finished). `react-native-shared-hero` is built for where React Native is today.

| | `react-native-shared-hero` | `react-native-shared-element` | `react-navigation-shared-element` |
| --- | --- | --- | --- |
| New Architecture (Fabric) | ✅ Built for it (Swift + Kotlin) | ❌ Predates it | ❌ Predates it |
| Maintenance | ✅ Actively developed | ⚠️ Seeking a maintainer | ⚠️ Seeking a maintainer |
| Setup | ✅ Declarative — drop `<SharedHero id namespace>` on both screens | ⚙️ Manual: capture nodes, render the transition overlay, drive a `position` value yourself | ✅ Declarative, but only via React Navigation |
| Navigator dependency | ✅ None (router-agnostic) | ✅ None (but you build the transition engine) | ❌ React Navigation only |
| Native Stack (`react-native-screens`) | ✅ First-class | n/a (primitive) | ❌ JS Stack only (Native Stack unfinished) |
| Beyond stack: modals / sheets / tabs / `FlatList` / in-place | ✅ All of these, plus the core `<Modal>` | ⚙️ Whatever your engine implements | ❌ JS Stack screens only |
| Interactive gesture return | ✅ iOS edge-swipe + sheet swipe-dismiss, synced to the transition coordinator | ➖ Driven by an external `position` value | ➖ Whatever the navigator provides |
| Fine-grained image resize / text-clip modes | ➖ Coarser (`snapshot` / `morph`, `fadeMode`) | ✅ Rich `resize` (auto/stretch/clip/none) + `align` matrix | ✅ Inherits the primitive's modes |
| Maturity / install base | 🆕 New | ✅ Battle-tested, large adoption | ✅ Battle-tested, large adoption |

**When the alternatives are still a good fit:** if you need the very granular image `resizeMode` transitions or text clip-reveal alignment that `react-native-shared-element` exposes, or you want a low-level `position`-driven primitive to wire into a custom (non-navigation) transition engine, those libraries remain excellent for that.

**Choose `react-native-shared-hero` when** you want a modern, New-Architecture-native, fully declarative shared-element library that works across your whole app — any navigator (or none), native stacks, modals, sheets, tabs, lists, and in-place toggles — with interactive gesture-driven returns out of the box.

## Requirements

- React Native **New Architecture (Fabric)** enabled — the component ships as a Fabric `codegenNativeComponent` and has no Paper/legacy fallback.
- iOS: Swift 5, C++20 (configured by the podspec).
- Android: `minSdkVersion` 24+.

The only peer dependencies are `react` and `react-native`. The library does **not** require `react-navigation` or `react-native-screens` — they are used only by the example app.

## Installation

```sh
npm install react-native-shared-hero
```

or

```sh
yarn add react-native-shared-hero
```

Then install pods for iOS:

```sh
cd ios && pod install
```

Make sure the New Architecture is enabled in your app (it is the default on recent React Native versions).

### Use with Expo

This library contains custom native code, so it **does not run in Expo Go**. Use an [Expo development build](https://docs.expo.dev/develop/development-builds/introduction/) instead — there's no config plugin to add, the module is autolinked during prebuild.

```sh
npx expo install react-native-shared-hero
```

Then build and run a development build (these run `prebuild` and compile the native project):

```sh
npx expo run:ios
# or
npx expo run:android
```

Or build it with [EAS](https://docs.expo.dev/develop/development-builds/create-a-build/):

```sh
eas build --profile development --platform ios   # or android
```

Requires the **New Architecture**, which is enabled by default on Expo SDK 52 and later. On older SDKs, enable it in `app.json` / `app.config.js`:

```json
{
  "expo": {
    "newArchEnabled": true
  }
}
```

## Quick start

Render a `SharedHero` with the same `id` (and `namespace`) on the two screens you want to connect. When one unmounts and the other mounts within roughly one native frame, the library captures the source and flies it into the destination automatically — no imperative calls, no navigation hooks.

```tsx
import { SharedHero } from 'react-native-shared-hero';
import { Image } from 'react-native';

// List screen
function ListItem({ photo, onPress }) {
  return (
    <Pressable onPress={onPress}>
      <SharedHero id={`photo-${photo.id}`} namespace="gallery" style={styles.thumb}>
        <Image source={{ uri: photo.uri }} style={styles.fill} />
      </SharedHero>
    </Pressable>
  );
}

// Detail screen
function Detail({ photo }) {
  return (
    <SharedHero id={`photo-${photo.id}`} namespace="gallery" style={styles.hero}>
      <Image source={{ uri: photo.uri }} style={styles.fill} />
    </SharedHero>
  );
}
```

That is the whole API for navigation-driven transitions. For same-screen toggles you can optionally use the [`useSharedHero`](#usesharedhero) helper.

## API reference

`SharedHero` (also exported as `SharedHeroView`) accepts all standard `ViewProps` (including `style` and `children`) plus the following:

| Prop | Type | Default | Description |
| --- | --- | --- | --- |
| `id` | `string` | — (required) | Stable identifier matched across screens. A flight runs when a hero with this `id` unmounts and another with the same `id` mounts within ~1 native frame. |
| `namespace` | `string` | `'default'` | Optional namespace; lets you run multiple isolated registries. Matching key is `namespace::id`. |
| `mode` | `'snapshot' \| 'morph' \| 'shuttle' \| 'zoom' \| 'auto'` | `'snapshot'` | Transition style. `snapshot`: clone, translate + scale + crossfade. `morph`: Material container transform (also interpolates corner radius + background color). `shuttle`: aliases `snapshot` in v1 (reserved for a v2 custom-subtree portal). `zoom`/`auto`: reserved for the iOS 18+ system zoom transition; **currently alias `morph`**. |
| `duration` | `number` | `320` | Animation duration in ms. Ignored when `spring` is set. |
| `spring` | `{ damping?: number; stiffness?: number; mass?: number }` | — | Spring config; overrides `duration`. A spring is used only when both `stiffness` and `mass` are non-zero. |
| `fadeMode` | `'cross' \| 'in' \| 'out' \| 'through'` | `'cross'` | How source/destination content fade during the flight. |
| `easing` | `'linear' \| 'easeIn' \| 'easeOut' \| 'easeInOut' \| 'standard' \| 'emphasized'` | `'standard'` | Easing preset for time-based flights. |
| `motionPath` | `'linear' \| 'arc'` | `'linear'` | Path of the flying element's centre. `linear`: straight line. `arc`: Material-style curved arc. |
| `enabled` | `boolean` | `true` | Disable participation in flights without unmounting. |
| `returnFlightEnabled` | `boolean` | `true` | Whether this hero produces a return (back) flight when it unmounts. Set `false` for a hero whose dismissal already carries the element away (e.g. a core `<Modal>` that slides down on dismiss), to avoid a redundant return flight. Only the unregister/back-flight path honours this; the inbound flight is unaffected. |
| `onTransitionStart` | `(e: { id: string; namespace: string }) => void` | — | Fires on the source view when its outbound flight starts. |
| `onTransitionEnd` | `(e: { id: string; namespace: string }) => void` | — | Fires on the destination view when its inbound flight ends. |

### `useSharedHero`

A small imperative helper for same-screen ("in-place") transitions. It does not talk to native — it just toggles React state so you can conditionally render two `SharedHero` subtrees with the same `id`; the library auto-detects the unmount→mount match within one frame.

```tsx
import { useSharedHero } from 'react-native-shared-hero';

const { active, toggle } = useSharedHero();

return (
  <Pressable onPress={toggle}>
    {active ? <ExpandedCard /> : <CollapsedCard />}
  </Pressable>
);
```

Returns `{ active, start, end, toggle }`. For navigation-driven flights you do not need this hook at all.

## Use cases

The sections below mirror the example app's screens (`example/src/screens/**`). Together they show how far an id-matched, router-agnostic model goes — from the simplest list→detail image to interactive gesture returns and cross-window modals. Run the [example app](#example-app) to see them all live.

Each use case has a placeholder table for your Android and iOS recordings.

### Basic image hero

The simplest case — a list thumbnail grows into the detail header using the default `snapshot` mode.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/8902a96b-59cf-4893-a0fd-a5b4316b4abd" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/65177700-0503-4ad5-9f7c-912f55cf6e45" controls loop muted></video> |

```tsx
// List
<SharedHero id={`basic-${photo.id}`} namespace="basic" mode="snapshot" duration={360} style={styles.thumbWrap}>
  <Image source={{ uri: photo.uri }} style={styles.thumb} />
</SharedHero>

// Detail — same id + namespace
<SharedHero id={`basic-${photo.id}`} namespace="basic" mode="snapshot" duration={360} style={styles.heroWrap}>
  <Image source={{ uri: photo.uri }} style={styles.hero} />
</SharedHero>
```

### FlatList (virtualized)

A shared hero originating in a virtualized `FlatList` of ~60 items — the source row may be recycled or unmounted while you scroll, yet the flight still resolves because matching is by `id`, not by view instance.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/e575ddb3-bc1d-4ba0-b692-46342e983ce8" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/c8b5e622-9479-480f-93aa-9da9fa00558a" controls loop muted></video> |

```tsx
const renderItem = ({ item }) => (
  <TouchableOpacity onPress={() => navigation.navigate('FlatListHeroDetail', { id: item.id })}>
    <SharedHero id={`flatlist-${item.id}`} namespace="flatlist" mode="snapshot" duration={360} style={styles.thumbWrap}>
      <Image source={{ uri: flatUri(item.id) }} style={styles.thumb} />
    </SharedHero>
  </TouchableOpacity>
);
```

### Card morph (Material container)

`mode="morph"` interpolates corner radius, background color and bounds together — the Material container transform.


| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/0d6a614a-0584-414a-ad20-b090a414ad8b" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/6f64a280-2c31-4d24-91b8-cabbf2e24a66" controls loop muted></video> |

```tsx
<SharedHero
  id={`card-${photo.id}`}
  namespace="card"
  mode="morph"
  duration={420}
  style={[styles.card, { backgroundColor: photo.color }]}
>
  <View style={styles.cardInner}>{/* image + text */}</View>
</SharedHero>
```

### Native modal hero

Push a `presentation: 'modal'` native-stack screen with a shared element. The hero traverses the modal boundary because the overlay renders at the window level.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/400aaaf4-834c-4b56-9685-039f550b3dae" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/fa454b2c-52eb-44e2-b1e0-2b4365894ead" controls loop muted></video> |

```tsx
<SharedHero id={`modal-${photo.id}`} namespace="modal" mode="snapshot" duration={380} style={styles.thumb}>
  <Image source={{ uri: photo.uri }} style={styles.fill} />
</SharedHero>
```

### Transparent modal hero

A `presentation: 'transparentModal'` screen — the case where the flying element would otherwise be obstructed. Window-level overlay rendering keeps the snapshot on top.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/75c35270-4264-45c0-be64-f53ea62a2bbf" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/67607ca1-05e3-4604-a151-5b175642d288" controls loop muted></video> |

```tsx
<SharedHero
  id={`tmodal-${photo.id}`}
  namespace="tmodal"
  mode="morph"
  duration={420}
  style={[styles.hero, { backgroundColor: photo.color }]}
>
  <Image source={{ uri: photo.uri }} style={styles.fill} />
</SharedHero>
```

### Tabs → detail hero

A card inside a custom in-screen tab pane pushes to a stack detail and the element still flies — the registry only cares about id matching, not which navigator (or tab) hosted the trigger.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/2de41d36-1a22-4064-b33c-3e498add10d0" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/e27aae00-8c37-461b-ba8f-b15f306cd52d" controls loop muted></video> |

```tsx
<SharedHero
  id={`tabs-${photo.id}`}
  namespace="tabs"
  mode="morph"
  duration={400}
  style={[styles.card, { backgroundColor: photo.color }]}
>
  <View style={styles.cardInner}>{/* thumb + text */}</View>
</SharedHero>
```

### FormSheet hero

A `presentation: 'formSheet'` screen — a true UIKit sheet on iOS, the native-stack sheet style on Android. The hero flies into the sheet body.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/33ab7627-e958-4477-8787-6642226c8a71" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/ad56aa9d-eb1f-4157-9c9e-1822f699d4fe" controls loop muted></video> |

```tsx
<SharedHero id={`sheet-${photo.id}`} namespace="sheet" mode="snapshot" duration={380} style={styles.hero}>
  <Image source={{ uri: photo.uri }} style={styles.fill} />
</SharedHero>
```

### In-place toggle

No navigation at all — a `useState` toggle swaps a small `SharedHero` for a large one with the same `id`. A distinct React `key` forces an unmount→mount of the same id within one commit, which is exactly the router-agnostic in-place match path.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/05a81333-c76f-4864-8047-4eb46a0e50d0" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/d3020dbc-cf82-4cc7-bf77-98509f474f57" controls loop muted></video> |

```tsx
{expanded ? (
  <SharedHero key="hero-inplace-large" id="hero-inplace" namespace="inplace" mode="snapshot" duration={420} style={styles.large}>
    <Image source={{ uri: PHOTO.uri }} style={styles.fill} />
  </SharedHero>
) : (
  <SharedHero key="hero-inplace-small" id="hero-inplace" namespace="inplace" mode="snapshot" duration={420} style={styles.small}>
    <Image source={{ uri: PHOTO.uri }} style={styles.fill} />
  </SharedHero>
)}
```

### Spring vs duration

The same hero with the two timing models side by side: a fixed `duration` with an easing curve, vs a physical `spring`.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/172f6e38-2c55-40dd-af5f-dfaae2eb79da" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/530774c9-15b4-45c1-a987-cc927c5e1c2c" controls loop muted></video> |

```tsx
// Duration timing
<SharedHero id="svd-duration" namespace="svd-duration" mode="morph" duration={360} style={styles.thumb}>
  <Image source={{ uri: PHOTO.uri }} style={styles.fill} />
</SharedHero>

// Spring timing
<SharedHero id="svd-spring" namespace="svd-spring" mode="morph" spring={{ damping: 16, stiffness: 200, mass: 1 }} style={styles.thumb}>
  <Image source={{ uri: PHOTO.uri }} style={styles.fill} />
</SharedHero>
```

### Arc path motion

`motionPath="arc"` traces a quadratic curve between the source and destination centres, paired here with the `emphasized` easing.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/1d951962-e393-48aa-8ad0-7e338a2d70f4" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/58a7ab8b-aaa6-4254-8d3c-1db7f883c528" controls loop muted></video> |

```tsx
<SharedHero
  id={`arc-${photo.id}`}
  namespace="arc"
  mode="morph"
  motionPath="arc"
  duration={520}
  easing="emphasized"
  style={[styles.thumb, { backgroundColor: photo.color }]}
>
  <Image source={{ uri: photo.uri }} style={styles.fill} />
</SharedHero>
```

### Custom shuttle

`fadeMode="through"` fades the source fully out before the destination's (totally different) layout fades in — Flutter's `flightShuttleBuilder` feel without the JSX gymnastics.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/8a489841-fea5-4fca-9728-2b549b0d6a0b" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/f5bd5d09-48c1-4b9c-9705-182d07dd9512" controls loop muted></video> |

```tsx
<SharedHero
  id={`shuttle-${photo.id}`}
  namespace="shuttle"
  mode="morph"
  fadeMode="through"
  duration={520}
  easing="emphasized"
  style={[styles.card, { backgroundColor: photo.color }]}
>
  {/* source: small thumb + label; destination: full-bleed hero */}
</SharedHero>
```

### Drag-to-dismiss (gesture return)

A gesture-driven interactive return. On iOS the left-edge swipe-back is tracked frame-by-frame and synced to the navigator's transition coordinator (see [ARCHITECTURE.md](./ARCHITECTURE.md)). The example also demonstrates a JS-driven drag whose release slingshots the hero back to its origin cell.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/00ddc9a8-edac-4734-b229-baa12f0f4294" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/0ffcaae6-be21-466a-9646-d9dc0a97e9b5" controls loop muted></video> |

```tsx
// Keeping the hero mounted inside the dragged wrapper means the back-flight
// captures a live source at the dragged position.
<Animated.View {...panResponder.panHandlers} style={[styles.heroOuter, { transform: [{ translateY }, { scale }] }]}>
  <SharedHero id={`gesture-${photo.id}`} namespace="gesture" mode="snapshot" duration={360} style={styles.heroWrap}>
    <Image source={{ uri: photo.uri }} style={styles.fill} />
  </SharedHero>
</Animated.View>
```

### Multi-step navigation

Each detail screen shows an "Up next" thumbnail; tapping it pushes a deeper detail whose big hero shares the tapped thumbnail's `id`, so a flight runs at every step of the chain.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/425bb373-5a88-46cf-8fa3-3207938fa06c" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/172ca32e-0e9a-44f0-8d69-90dcfad1c36e" controls loop muted></video> |

```tsx
// Big hero for the current photo
<SharedHero id={`multi-${id}`} namespace="multi" mode="snapshot" duration={360} style={styles.heroWrap}>
  <Image source={{ uri: photo.uri }} style={styles.hero} />
</SharedHero>

// "Up next" thumbnail — its id matches the next step's big hero
<SharedHero id={`multi-${nextPhoto.id}`} namespace="multi" mode="snapshot" duration={360} style={styles.nextThumbWrap}>
  <Image source={{ uri: nextPhoto.uri }} style={styles.nextThumb} />
</SharedHero>
```

### Core Modal (React Native)

A hero into React Native's core `<Modal>` — on iOS a separate `UIWindow` (`RCTModalHostView`) outside the navigator, on Android a separate `Dialog` window. The overlay is layered above that window so the flight stays visible; `returnFlightEnabled={false}` is **not** used here, but the dismiss is a plain slide so the same id matches back to the list thumbnail.

| Android | iOS |
| --- | --- |
| <video src="https://github.com/user-attachments/assets/eb76f4bc-1014-4abd-b626-851b7577c9e9" controls loop muted></video> | <video src="https://github.com/user-attachments/assets/d70f7f85-8db7-482f-89af-d3dcba0d1169" controls loop muted></video> |

```tsx
// Trigger in the list
<SharedHero id={`core-modal-${photo.id}`} namespace="core-modal" mode="snapshot" duration={380} style={styles.thumb}>
  <Image source={{ uri: photo.uri }} style={styles.fill} />
</SharedHero>

// Destination inside RN's <Modal>
<Modal visible transparent animationType="slide" onRequestClose={close}>
  <SharedHero id={`core-modal-${active.id}`} namespace="core-modal" mode="snapshot" duration={380} style={styles.hero}>
    <Image source={{ uri: active.uri }} style={styles.fill} />
  </SharedHero>
</Modal>
```

## Example app

The `example/` workspace contains every use case above, wired through `@react-navigation/native-stack` + `react-native-screens` (used purely to demonstrate router-agnosticism — the library does not depend on them).

```sh
yarn            # install from the repo root (uses Yarn workspaces)
yarn example start

# in another terminal
yarn example ios
# or
yarn example android
```

## Under the hood

The interesting parts are native (Swift/Kotlin). Two docs go deep:

- [ARCHITECTURE.md](./ARCHITECTURE.md) — how the registry, snapshots, flights, overlay, and the interactive controllers work, plus the react-native-screens / navigation interop.
- [LESSONS_LEARNED.md](./LESSONS_LEARNED.md) — the hard-won bugs, cross-window gotchas, and design decisions behind the current shape (and the rules that keep them from coming back).

## Contributing

- [Development workflow](CONTRIBUTING.md#development-workflow)
- [Sending a pull request](CONTRIBUTING.md#sending-a-pull-request)
- [Code of conduct](CODE_OF_CONDUCT.md)

---

## License

MIT © Duc Trung Mai

---

Made with [create-react-native-library](https://github.com/callstack/react-native-builder-bob).
