import {
  Image,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { useNavigation, useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { SharedHero } from 'react-native-shared-hero';
import { PHOTOS, photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

// ID-SHARING SCHEME
// -----------------
// Every photo's hero uses id `multi-${photoId}` in namespace "multi".
// A step's screen shows the CURRENT photo as a big hero `multi-${id}` and an
// "Up next" thumbnail for the NEXT photo `multi-${nextId}`. Tapping "Up next"
// pushes a new Detail whose big hero is `multi-${nextId}` — the SAME id as the
// thumbnail just tapped, so the registry matches them and the element flies.
// Because react-native-screens detaches covered screens, only the top screen's
// heroes are live during a transition, so reusing photo ids across steps is
// safe even though the route name repeats. The chain cycles through PHOTOS
// (wrap with modulo).
export default function MultiStepDetail() {
  const route = useRoute<RouteProp<RootStackParamList, 'MultiStepDetail'>>();
  const navigation =
    useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  const { id, depth } = route.params;
  const photo = photoById(id);
  const nextIndex = (PHOTOS.findIndex((p) => p.id === id) + 1) % PHOTOS.length;
  const nextPhoto = PHOTOS[nextIndex]!;

  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="never"
      contentContainerStyle={styles.container}
    >
      <SharedHero
        id={`multi-${id}`}
        namespace="multi"
        mode="snapshot"
        duration={360}
        style={styles.heroWrap}
      >
        <Image source={{ uri: photo.uri }} style={styles.hero} />
      </SharedHero>
      <View style={styles.body}>
        <View style={styles.stepBadge}>
          <Text style={styles.stepBadgeText}>Step {depth}</Text>
        </View>
        <Text style={styles.title}>{photo.title}</Text>
        <Text style={styles.subtitle}>{photo.subtitle}</Text>
        <Text style={styles.paragraph}>
          This screen is reused at every depth. Tapping “Up next” pushes a new
          instance whose big hero shares the same id as the thumbnail you tap,
          so the element flies from here into the next step.
        </Text>

        <Text style={styles.sectionLabel}>Up next</Text>
        <TouchableOpacity
          activeOpacity={0.9}
          onPress={() =>
            navigation.push('MultiStepDetail', {
              id: nextPhoto.id,
              depth: depth + 1,
            })
          }
        >
          <SharedHero
            id={`multi-${nextPhoto.id}`}
            namespace="multi"
            mode="snapshot"
            duration={360}
            style={styles.nextThumbWrap}
          >
            <Image source={{ uri: nextPhoto.uri }} style={styles.nextThumb} />
          </SharedHero>
          <Text style={styles.nextTitle}>{nextPhoto.title}</Text>
        </TouchableOpacity>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { paddingBottom: 32 },
  heroWrap: { width: '100%', aspectRatio: 4 / 3, backgroundColor: '#eee' },
  hero: { width: '100%', height: '100%' },
  body: { padding: 20 },
  stepBadge: {
    alignSelf: 'flex-start',
    paddingHorizontal: 10,
    paddingVertical: 3,
    backgroundColor: '#111',
    borderRadius: 999,
    marginBottom: 10,
  },
  stepBadgeText: {
    color: '#fff',
    fontSize: 11,
    fontWeight: '700',
    letterSpacing: 0.5,
  },
  title: { fontSize: 24, fontWeight: '700', color: '#111' },
  subtitle: { fontSize: 15, color: '#666', marginTop: 4 },
  paragraph: { fontSize: 15, color: '#333', marginTop: 16, lineHeight: 22 },
  sectionLabel: {
    fontSize: 13,
    fontWeight: '700',
    color: '#888',
    letterSpacing: 0.5,
    textTransform: 'uppercase',
    marginTop: 28,
    marginBottom: 10,
  },
  nextThumbWrap: {
    width: '60%',
    aspectRatio: 4 / 3,
    borderRadius: 14,
    overflow: 'hidden',
    backgroundColor: '#eee',
  },
  nextThumb: { width: '100%', height: '100%' },
  nextTitle: { fontSize: 15, fontWeight: '600', color: '#111', marginTop: 8 },
});
