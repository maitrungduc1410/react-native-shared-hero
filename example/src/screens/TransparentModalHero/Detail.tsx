import {
  Image,
  Pressable,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { useNavigation, useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function TransparentModalHeroDetail() {
  const route =
    useRoute<RouteProp<RootStackParamList, 'TransparentModalHeroDetail'>>();
  const nav = useNavigation();
  const photo = photoById(route.params.id);
  return (
    <View style={styles.root}>
      <Pressable style={styles.scrim} onPress={() => nav.goBack()} />
      <View style={styles.sheet}>
        <SharedHero
          id={`tmodal-${photo.id}`}
          namespace="tmodal"
          mode="morph"
          duration={420}
          style={[styles.hero, { backgroundColor: photo.color }]}
        >
          <Image source={{ uri: photo.uri }} style={styles.fill} />
        </SharedHero>
        <View style={styles.body}>
          <Text style={styles.title}>{photo.title}</Text>
          <Text style={styles.subtitle}>{photo.subtitle}</Text>
          <Text style={styles.paragraph}>
            The transparent modal lets the underlying screen show through.
            Without window-level overlay rendering, the flying snapshot would
            disappear behind the modal.
          </Text>
          <TouchableOpacity onPress={() => nav.goBack()} style={styles.button}>
            <Text style={styles.buttonText}>Close</Text>
          </TouchableOpacity>
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, justifyContent: 'flex-end' },
  scrim: {
    position: 'absolute',
    top: 0,
    bottom: 0,
    left: 0,
    right: 0,
    backgroundColor: 'rgba(0,0,0,0.45)',
  },
  sheet: {
    backgroundColor: '#fff',
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    overflow: 'hidden',
  },
  hero: { width: '100%', aspectRatio: 16 / 9, overflow: 'hidden' },
  fill: { width: '100%', height: '100%' },
  body: { padding: 20 },
  title: { fontSize: 22, fontWeight: '700', color: '#111' },
  subtitle: { fontSize: 14, color: '#555', marginTop: 4 },
  paragraph: { fontSize: 15, color: '#333', marginTop: 14, lineHeight: 22 },
  button: {
    marginTop: 18,
    alignSelf: 'flex-start',
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: '#111',
    borderRadius: 999,
  },
  buttonText: { color: '#fff', fontWeight: '600' },
});
