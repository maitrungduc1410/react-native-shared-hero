# react-native-shared-hero

## 1.0.5

### Patch Changes

- 97f1392: Skip pairing a newly registered iOS hero with a twin whose deferred unregister opted out of return flights (`returnFlightEnabled={false}`), preventing bogus mid-scroll flights during horizontal pager handovers (#13).

## 1.0.4

### Patch Changes

- 012d72d: Improve native flight reliability, image transitions, interactive pop gestures, and snapshot caching on iOS and Android:
  
  - Fix compilation on React Native 0.82 and under `use_frameworks!` on iOS (#1).
  - Register iOS heroes only while attached to a window and keep unregistered sources matchable through Fabric stack pops (#2, #3).
  - Bound the last-known-good snapshot cache on both platforms and skip pre-layout snapshots on Android (#4).
  - Fly the destination's higher-resolution image on zoom-in between image-only heroes once it has loaded (#5).
  - Start return flights from the hero's live on-screen rect (#6).
  - Remove recycled Android heroes from their previous `id` bucket when `id` or `namespace` changes (#7).
  - Allow a newer flight on the same hero key to take over an in-flight transition cleanly (#8).
  - Hide the outgoing Android hero as soon as its return flight starts and clear the flag on recycle (#9).
  - Skip iOS swipe-back tracking when interactive pop is disabled and re-arm cleanly on driver hand-over (#10).
  - Skip redundant Android snapshot stash renders when nothing reads the stash or the image has not changed (#11).

## Older releases

Releases up to 1.0.3 are documented in
[GitHub Releases](https://github.com/maitrungduc1410/react-native-shared-hero/releases).
