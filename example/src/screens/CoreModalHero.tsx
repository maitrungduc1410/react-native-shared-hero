import { useState } from 'react';
import {
  Image,
  Modal,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { SharedHero } from 'react-native-shared-hero';
import { PHOTOS, photoById } from '../data';

export default function CoreModalHero() {
  const [activeId, setActiveId] = useState<string | null>(null);
  const active = activeId ? photoById(activeId) : null;
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      <Text style={styles.intro}>
        Tap an image to open React Native's core `&lt;Modal&gt;` (not a
        native-stack presentation). On iOS this is hosted in a separate UIWindow
        outside the navigator hierarchy, so it's a good place to observe how the
        hero behaves across that boundary.
      </Text>
      {PHOTOS.slice(0, 4).map((photo) => (
        <TouchableOpacity
          key={photo.id}
          activeOpacity={0.9}
          onPress={() => setActiveId(photo.id)}
        >
          <SharedHero
            id={`core-modal-${photo.id}`}
            namespace="core-modal"
            mode="snapshot"
            duration={380}
            style={styles.thumb}
          >
            <Image source={{ uri: photo.uri }} style={styles.fill} />
          </SharedHero>
        </TouchableOpacity>
      ))}
      {/* Open slides the page up from the bottom (a real entrance for the hero to
          fly into). On dismiss the content unmounts immediately, so the chrome
          disappears at once while the hero flies back to its list thumbnail as a
          clean shared-element return — the empty transparent window's slide-out
          is invisible, so there's no white flash. `transparent` avoids an opaque
          white window; `statusBarTranslucent` + `navigationBarTranslucent` keep
          the slide full-bleed on Android (no bottom gap). */}
      <Modal
        visible={active != null}
        transparent
        animationType="slide"
        statusBarTranslucent
        navigationBarTranslucent
        onRequestClose={() => setActiveId(null)}
      >
        {active ? (
          <View style={styles.modalRoot}>
            <SharedHero
              id={`core-modal-${active.id}`}
              namespace="core-modal"
              mode="snapshot"
              duration={380}
              style={styles.hero}
            >
              <Image source={{ uri: active.uri }} style={styles.fill} />
            </SharedHero>
            <View style={styles.body}>
              <Text style={styles.title}>{active.title}</Text>
              <Text style={styles.subtitle}>{active.subtitle}</Text>
              <Text style={styles.paragraph}>
                This destination lives inside React Native's core
                `&lt;Modal&gt;`. On iOS the modal content is mounted in its own
                UIWindow (`RCTModalHostView`), which sits outside the
                native-stack screen hierarchy — unlike the `presentation:
                'modal'` example, which is a native-stack screen.
              </Text>
              <TouchableOpacity
                onPress={() => setActiveId(null)}
                style={styles.button}
              >
                <Text style={styles.buttonText}>Dismiss</Text>
              </TouchableOpacity>
            </View>
          </View>
        ) : null}
      </Modal>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { padding: 16, paddingBottom: 32 },
  intro: { fontSize: 14, color: '#555', marginBottom: 12 },
  thumb: {
    width: '100%',
    aspectRatio: 16 / 10,
    borderRadius: 14,
    overflow: 'hidden',
    backgroundColor: '#eee',
    marginBottom: 12,
  },
  fill: { width: '100%', height: '100%' },
  modalRoot: { flex: 1, backgroundColor: '#fff' },
  hero: { width: '100%', aspectRatio: 16 / 10, backgroundColor: '#eee' },
  body: { padding: 20 },
  title: { fontSize: 22, fontWeight: '700', color: '#111' },
  subtitle: { fontSize: 14, color: '#555', marginTop: 4 },
  paragraph: { fontSize: 15, color: '#333', marginTop: 14, lineHeight: 22 },
  button: {
    marginTop: 24,
    alignSelf: 'flex-start',
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: '#111',
    borderRadius: 999,
  },
  buttonText: { color: '#fff', fontWeight: '600' },
});
