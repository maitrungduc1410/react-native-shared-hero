import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function CardMorphDetail() {
  const route = useRoute<RouteProp<RootStackParamList, 'CardMorphDetail'>>();
  const photo = photoById(route.params.id);
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="never"
      contentContainerStyle={styles.container}
    >
      <SharedHero
        id={`card-${photo.id}`}
        namespace="card"
        mode="morph"
        duration={420}
        style={[styles.hero, { backgroundColor: photo.color }]}
      >
        <View style={styles.heroInner}>
          <Image source={{ uri: photo.uri }} style={styles.heroImage} />
          <View style={styles.heroText}>
            <Text style={styles.title}>{photo.title}</Text>
            <Text style={styles.subtitle}>{photo.subtitle}</Text>
          </View>
        </View>
      </SharedHero>
      <View style={styles.body}>
        <Text style={styles.paragraph}>
          This is the Material container transform — the rounded card morphs its
          bounds, corner radius, and background color simultaneously to form the
          detail header. The destination corner radius is 0 (square edges), so
          the card flattens out as it expands.
        </Text>
        <Text style={styles.paragraph}>
          The transition is fully native: on iOS we interpolate{' '}
          layer.cornerRadius and backgroundColor inside a UIWindow overlay; on
          Android we drive a ViewOutlineProvider on a FrameLayout in the
          activity decor's overlay.
        </Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { paddingBottom: 32 },
  hero: {
    width: '100%',
    height: 280,
    borderRadius: 0,
    overflow: 'hidden',
  },
  heroInner: { flex: 1 },
  heroImage: { width: '100%', height: '100%', position: 'absolute' },
  heroText: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    padding: 20,
    backgroundColor: 'rgba(0,0,0,0.35)',
  },
  title: { fontSize: 22, fontWeight: '700', color: '#fff' },
  subtitle: { fontSize: 14, color: 'rgba(255,255,255,0.9)', marginTop: 2 },
  body: { padding: 20 },
  paragraph: { fontSize: 15, color: '#333', marginTop: 12, lineHeight: 22 },
});
