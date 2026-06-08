import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import type { RootStackParamList } from '../../navigation';
import { flatUri } from './List';

export default function FlatListHeroDetail() {
  const route = useRoute<RouteProp<RootStackParamList, 'FlatListHeroDetail'>>();
  const { id } = route.params;
  // Recompute the image from the id alone — the uri is never passed through
  // navigation params, mirroring how a real virtualized list would work.
  const uri = flatUri(id);
  const title = `Photo #${id}`;
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="never"
      contentContainerStyle={styles.container}
    >
      <SharedHero
        id={`flatlist-${id}`}
        namespace="flatlist"
        mode="snapshot"
        duration={360}
        style={styles.heroWrap}
      >
        <Image source={{ uri }} style={styles.hero} />
      </SharedHero>
      <View style={styles.body}>
        <Text style={styles.title}>{title}</Text>
        <Text style={styles.paragraph}>
          This thumbnail came from a FlatList with dozens of items, where the
          row that hosted it may have been recycled or unmounted while you
          scrolled. The registry matches heroes by id, so the flight still
          resolves correctly regardless of virtualization.
        </Text>
        <Text style={styles.paragraph}>
          The image is recomputed from the item id alone, so no bitmap or uri
          needs to be threaded through navigation params.
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
  paragraph: { fontSize: 15, color: '#333', marginTop: 16, lineHeight: 22 },
});
