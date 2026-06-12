import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { useNavigation, useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function TextHeroDetail() {
  const route = useRoute<RouteProp<RootStackParamList, 'TextHeroDetail'>>();
  const nav = useNavigation();
  const photo = photoById(route.params.id);
  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <SharedHero
          id={`text-title-${photo.id}`}
          namespace="text"
          mode="snapshot"
          style={styles.heroWrap}
        >
          {/* Large headline; long titles wrap to two lines here while the list
              showed them on one. The aspect-fit flight handles that shape change
              without cropping. */}
          <Text
            numberOfLines={1}
            adjustsFontSizeToFit
            minimumFontScale={0.5}
            style={styles.title}
          >
            {photo.title}
          </Text>
        </SharedHero>
        <SharedHero
          id={`text-sub-${photo.id}`}
          namespace="text"
          mode="snapshot"
          style={styles.heroWrap}
        >
          <Text style={styles.subtitle}>{photo.subtitle}</Text>
        </SharedHero>
      </View>
      <View style={styles.body}>
        <Text style={styles.paragraph}>
          The title and subtitle above flew here from the list row. Both grew
          several times in size and moved across the screen, and the flying
          snapshot scaled uniformly the whole way — no clipped glyphs, even when
          the headline re-wraps to a different number of lines.
        </Text>
        <TouchableOpacity onPress={() => nav.goBack()} style={styles.button}>
          <Text style={styles.buttonText}>Back</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff' },
  header: { paddingTop: 120, paddingHorizontal: 20 },
  heroWrap: { alignSelf: 'flex-start' },
  title: {
    fontSize: 44,
    fontWeight: '800',
    color: '#111',
    letterSpacing: -0.5,
  },
  subtitle: { fontSize: 18, color: '#666', marginTop: 8 },
  body: { padding: 20 },
  paragraph: { fontSize: 15, color: '#333', lineHeight: 22 },
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
