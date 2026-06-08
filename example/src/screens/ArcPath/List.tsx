import {
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { SharedHero } from 'react-native-shared-hero';
import { PHOTOS } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function ArcPathList() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      <Text style={styles.intro}>
        With `motionPath="arc"` the flying element traces a quadratic curve
        between source and destination centres. Tap an item.
      </Text>
      <View style={styles.grid}>
        {PHOTOS.slice(0, 4).map((photo) => (
          <Pressable
            key={photo.id}
            style={styles.cell}
            onPress={() => nav.navigate('ArcPathDetail', { id: photo.id })}
          >
            <SharedHero
              id={`arc-${photo.id}`}
              namespace="arc"
              mode="morph"
              motionPath="arc"
              duration={520}
              easing="emphasized"
              style={[styles.thumb, { backgroundColor: photo.color }]}
            >
              <Image source={{ uri: photo.uri }} style={styles.fill} />
            </SharedHero>
            <Text style={styles.label}>{photo.title}</Text>
          </Pressable>
        ))}
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { padding: 16, paddingBottom: 32 },
  intro: { fontSize: 14, color: '#555', marginBottom: 16 },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: 12 },
  cell: { width: '47%' },
  thumb: {
    width: '100%',
    aspectRatio: 1,
    borderRadius: 16,
    overflow: 'hidden',
  },
  fill: { width: '100%', height: '100%' },
  label: { marginTop: 6, fontSize: 13, color: '#444' },
});
