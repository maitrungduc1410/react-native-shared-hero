import {
  Image,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { SharedHero } from 'react-native-shared-hero';
import { PHOTOS } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function BasicImageHeroList() {
  const navigation =
    useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      {PHOTOS.map((photo) => (
        <TouchableOpacity
          key={photo.id}
          activeOpacity={0.9}
          onPress={() =>
            navigation.navigate('BasicImageHeroDetail', { id: photo.id })
          }
        >
          <SharedHero
            id={`basic-${photo.id}`}
            namespace="basic"
            mode="snapshot"
            duration={360}
            style={styles.thumbWrap}
          >
            <Image source={{ uri: photo.uri }} style={styles.thumb} />
          </SharedHero>
          <View style={styles.captionWrap}>
            <Text style={styles.title}>{photo.title}</Text>
            <Text style={styles.subtitle}>{photo.subtitle}</Text>
          </View>
        </TouchableOpacity>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { padding: 16, paddingBottom: 32 },
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
  subtitle: { fontSize: 13, color: '#666', marginTop: 2 },
});
