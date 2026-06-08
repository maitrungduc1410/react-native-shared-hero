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
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function SheetHeroDetail() {
  const route = useRoute<RouteProp<RootStackParamList, 'SheetHeroDetail'>>();
  const nav = useNavigation();
  const photo = photoById(route.params.id);
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      <SharedHero
        id={`sheet-${photo.id}`}
        namespace="sheet"
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
          Sheets are tricky because on Android they may live in a separate
          Window. Our overlay is the activity's decor view overlay — Phase 4
          will add cross-window flight support for those edge cases.
        </Text>
        <TouchableOpacity onPress={() => nav.goBack()} style={styles.button}>
          <Text style={styles.buttonText}>Dismiss</Text>
        </TouchableOpacity>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { paddingBottom: 32 },
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
