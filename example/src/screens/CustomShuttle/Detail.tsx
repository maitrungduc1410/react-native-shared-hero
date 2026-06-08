import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function CustomShuttleDetail() {
  const route =
    useRoute<RouteProp<RootStackParamList, 'CustomShuttleDetail'>>();
  const photo = photoById(route.params.id);
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="never"
      contentContainerStyle={styles.container}
    >
      <SharedHero
        id={`shuttle-${photo.id}`}
        namespace="shuttle"
        mode="morph"
        fadeMode="through"
        duration={520}
        easing="emphasized"
        style={[styles.hero, { backgroundColor: photo.color }]}
      >
        <View style={styles.heroInner}>
          <Image source={{ uri: photo.uri }} style={styles.heroImage} />
          <View style={styles.heroOverlay}>
            <Text style={styles.heroEyebrow}>FEATURED</Text>
            <Text style={styles.heroTitle}>{photo.title}</Text>
            <Text style={styles.heroBody}>{photo.subtitle}</Text>
          </View>
        </View>
      </SharedHero>
      <View style={styles.body}>
        <Text style={styles.paragraph}>
          The source card had a tiny thumbnail and one-line label. The
          destination has a full-bleed image, an eyebrow, a title, and a body.
          Because `fadeMode="through"`, the source cleanly disappears before the
          destination appears — no overlapping content fight.
        </Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { paddingBottom: 32 },
  hero: { width: '100%', height: 320, overflow: 'hidden' },
  heroInner: { flex: 1 },
  heroImage: { width: '100%', height: '100%', position: 'absolute' },
  heroOverlay: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    padding: 20,
    backgroundColor: 'rgba(0,0,0,0.35)',
  },
  heroEyebrow: {
    fontSize: 11,
    fontWeight: '700',
    letterSpacing: 1.2,
    color: '#fff',
    marginBottom: 6,
  },
  heroTitle: { fontSize: 24, fontWeight: '700', color: '#fff' },
  heroBody: { fontSize: 14, color: 'rgba(255,255,255,0.9)', marginTop: 4 },
  body: { padding: 20 },
  paragraph: { fontSize: 15, color: '#333', lineHeight: 22 },
});
