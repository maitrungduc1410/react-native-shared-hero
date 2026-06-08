import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function BasicImageHeroDetail() {
  const route =
    useRoute<RouteProp<RootStackParamList, 'BasicImageHeroDetail'>>();
  const photo = photoById(route.params.id);
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="never"
      contentContainerStyle={styles.container}
    >
      <SharedHero
        id={`basic-${photo.id}`}
        namespace="basic"
        mode="snapshot"
        duration={360}
        style={styles.heroWrap}
      >
        <Image source={{ uri: photo.uri }} style={styles.hero} />
      </SharedHero>
      <View style={styles.body}>
        <Text style={styles.title}>{photo.title}</Text>
        <Text style={styles.subtitle}>{photo.subtitle}</Text>
        <Text style={styles.paragraph}>
          The shared hero element seamlessly transitions from the list grid into
          this header. This is the simplest mode — `snapshot` — which captures
          source and destination bitmaps and crossfades them while the container
          morphs from the source rect to the destination rect.
        </Text>
        <Text style={styles.paragraph}>
          Because the registry matches by id and not by navigation event, the
          same code works for tabs, modals and in-place state toggles too.
        </Text>
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
  title: { fontSize: 24, fontWeight: '700', color: '#111' },
  subtitle: { fontSize: 15, color: '#666', marginTop: 4 },
  paragraph: { fontSize: 15, color: '#333', marginTop: 16, lineHeight: 22 },
});
