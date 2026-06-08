import { Image, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { useNavigation, useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function ModalHeroDetail() {
  const route = useRoute<RouteProp<RootStackParamList, 'ModalHeroDetail'>>();
  const nav = useNavigation();
  const photo = photoById(route.params.id);
  return (
    <View style={styles.container}>
      <SharedHero
        id={`modal-${photo.id}`}
        namespace="modal"
        mode="snapshot"
        duration={380}
        style={styles.hero}
      >
        <Image source={{ uri: photo.uri }} style={styles.fill} />
      </SharedHero>
      <View style={styles.body}>
        <Text style={styles.title}>{photo.title}</Text>
        <Text style={styles.subtitle}>{photo.subtitle}</Text>
        <Text style={styles.paragraph}>
          This screen is a `presentation: 'modal'` native-stack screen — a full
          UIKit modal on iOS, a fragment-style modal on Android. The shared
          element traverses the modal boundary because our overlay renders at
          the window level.
        </Text>
        <TouchableOpacity onPress={() => nav.goBack()} style={styles.button}>
          <Text style={styles.buttonText}>Dismiss</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff' },
  hero: { width: '100%', aspectRatio: 16 / 10, backgroundColor: '#eee' },
  fill: { width: '100%', height: '100%' },
  body: { padding: 20 },
  title: { fontSize: 22, fontWeight: '700', color: '#111' },
  subtitle: { fontSize: 14, color: '#555', marginTop: 4 },
  paragraph: { fontSize: 15, color: '#333', marginTop: 14, lineHeight: 22 },
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
