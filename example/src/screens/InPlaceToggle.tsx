import { useState } from 'react';
import { Image, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { SharedHero } from 'react-native-shared-hero';
import { PHOTOS } from '../data';

const PHOTO = PHOTOS[0]!;

/**
 * Demonstrates that shared-hero matching is router-agnostic: we only swap
 * which subtree renders the `SharedHero` with `id="hero-inplace"`, and the
 * library still runs a flight between source and destination rects on the
 * same screen.
 */
export default function InPlaceToggle() {
  const [expanded, setExpanded] = useState(false);
  return (
    <View style={styles.container}>
      <Text style={styles.heading}>Tap the image</Text>
      <Text style={styles.subheading}>
        No navigation involved. State toggle, same screen.
      </Text>
      <TouchableOpacity
        activeOpacity={0.9}
        onPress={() => setExpanded((e) => !e)}
      >
        {expanded ? (
          // The `key` is what makes this work: it differs between the two
          // states, so React UNMOUNTS the small hero and MOUNTS a distinct
          // large hero within the same commit (rather than reusing one
          // instance and just diffing the `style` prop). That unmount→mount
          // of the same `id` within one runloop tick is exactly the
          // router-agnostic in-place match path the registry fires on.
          <SharedHero
            key="hero-inplace-large"
            id="hero-inplace"
            namespace="inplace"
            mode="snapshot"
            duration={420}
            style={styles.large}
          >
            <Image source={{ uri: PHOTO.uri }} style={styles.fill} />
          </SharedHero>
        ) : (
          <SharedHero
            key="hero-inplace-small"
            id="hero-inplace"
            namespace="inplace"
            mode="snapshot"
            duration={420}
            style={styles.small}
          >
            <Image source={{ uri: PHOTO.uri }} style={styles.fill} />
          </SharedHero>
        )}
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    alignItems: 'center',
    paddingTop: 32,
  },
  heading: { fontSize: 22, fontWeight: '700', color: '#111' },
  subheading: { fontSize: 14, color: '#666', marginTop: 4, marginBottom: 24 },
  small: { width: 120, height: 120, borderRadius: 12, overflow: 'hidden' },
  large: { width: 320, height: 320, borderRadius: 24, overflow: 'hidden' },
  fill: { width: '100%', height: '100%' },
});
