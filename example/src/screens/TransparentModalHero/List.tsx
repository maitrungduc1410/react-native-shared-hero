import {
  Image,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
} from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { SharedHero } from 'react-native-shared-hero';
import { PHOTOS } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function TransparentModalHeroList() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      <Text style={styles.intro}>
        This is the case Reanimated SET cannot do correctly on iOS yet — the
        flying element would be obstructed by the transparent modal. We render
        at window level so it stays on top.
      </Text>
      {PHOTOS.slice(0, 4).map((photo) => (
        <TouchableOpacity
          key={photo.id}
          activeOpacity={0.9}
          onPress={() =>
            nav.navigate('TransparentModalHeroDetail', { id: photo.id })
          }
        >
          <SharedHero
            id={`tmodal-${photo.id}`}
            namespace="tmodal"
            mode="morph"
            duration={420}
            style={[styles.card, { backgroundColor: photo.color }]}
          >
            <Image source={{ uri: photo.uri }} style={styles.thumb} />
          </SharedHero>
        </TouchableOpacity>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { padding: 16, paddingBottom: 32 },
  intro: { fontSize: 14, color: '#555', marginBottom: 12 },
  card: {
    width: '100%',
    height: 140,
    borderRadius: 20,
    overflow: 'hidden',
    marginBottom: 12,
  },
  thumb: { width: '100%', height: '100%' },
});
