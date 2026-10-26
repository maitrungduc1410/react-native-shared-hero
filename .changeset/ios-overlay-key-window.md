---
'react-native-shared-hero': patch
---

Make the iOS overlay window take its status bar, home indicator and supported orientations from the scene's key window instead of the highest-level window (`UITextEffectsWindow`), so the overlay no longer keeps the app in a stale orientation after the scene moves to another display, e.g. iPhone Duo fold/unfold (#15).
