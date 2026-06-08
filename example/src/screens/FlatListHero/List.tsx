import {
  FlatList,
  Image,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
  type ListRenderItem,
} from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { SharedHero } from 'react-native-shared-hero';
import type { RootStackParamList } from '../../navigation';

// Deterministic seed-based picsum URL so the Detail screen can recompute the
// exact same image from just the id — no uri is passed through navigation.
export function flatUri(id: string): string {
  return `https://picsum.photos/seed/flat${id}/600/400`;
}

type FlatItem = { id: string; title: string };

// ~60 items so FlatList virtualization (view recycling) actually kicks in.
const DATA: FlatItem[] = Array.from({ length: 60 }, (_, i) => {
  const id = String(i);
  return { id, title: `Photo #${id}` };
});

export default function FlatListHeroList() {
  const navigation =
    useNavigation<NativeStackNavigationProp<RootStackParamList>>();

  const renderItem: ListRenderItem<FlatItem> = ({ item }) => (
    <TouchableOpacity
      activeOpacity={0.9}
      onPress={() => navigation.navigate('FlatListHeroDetail', { id: item.id })}
    >
      <SharedHero
        id={`flatlist-${item.id}`}
        namespace="flatlist"
        mode="snapshot"
        duration={360}
        style={styles.thumbWrap}
      >
        <Image source={{ uri: flatUri(item.id) }} style={styles.thumb} />
      </SharedHero>
      <View style={styles.captionWrap}>
        <Text style={styles.title}>{item.title}</Text>
      </View>
    </TouchableOpacity>
  );

  return (
    <FlatList
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
      data={DATA}
      keyExtractor={(item) => item.id}
      renderItem={renderItem}
      ListHeaderComponent={
        <Text style={styles.intro}>
          A virtualized FlatList of {DATA.length} items. Rows are recycled as
          you scroll, yet tapping any thumbnail still flies it into the detail
          screen — proving shared-hero transitions survive virtualization.
        </Text>
      }
    />
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { padding: 16, paddingBottom: 32 },
  intro: { fontSize: 14, color: '#555', marginBottom: 16, lineHeight: 20 },
  thumbWrap: {
    width: '100%',
    aspectRatio: 4 / 3,
    borderRadius: 16,
    overflow: 'hidden',
    backgroundColor: '#eee',
  },
  thumb: { width: '100%', height: '100%' },
  captionWrap: { paddingHorizontal: 4, paddingVertical: 12, marginBottom: 16 },
  title: { fontSize: 17, fontWeight: '600', color: '#111' },
});
