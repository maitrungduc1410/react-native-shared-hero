import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function TabsHeroDetail() {
  const route = useRoute<RouteProp<RootStackParamList, 'TabsHeroDetail'>>();
  const photo = photoById(route.params.id);
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="never"
      contentContainerStyle={styles.container}
    >
      <SharedHero
        id={`tabs-${photo.id}`}
        namespace="tabs"
        mode="morph"
        duration={400}
        style={[styles.hero, { backgroundColor: photo.color }]}
      >
        <Image source={{ uri: photo.uri }} style={styles.fill} />
      </SharedHero>
      <View style={styles.body}>
        <Text style={styles.title}>{photo.title}</Text>
        <Text style={styles.subtitle}>{photo.subtitle}</Text>
        <Text style={styles.paragraph}>
          Reanimated's SET specifically does not work when the source is in a
          tab navigator — there is no flight. Our registry doesn't care about
          navigators, only id-matching across mount/unmount within one frame.
        </Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { paddingBottom: 32 },
  hero: { width: '100%', height: 260, overflow: 'hidden' },
  fill: { width: '100%', height: '100%' },
  body: { padding: 20 },
  title: { fontSize: 22, fontWeight: '700', color: '#111' },
  subtitle: { fontSize: 14, color: '#555', marginTop: 4 },
  paragraph: { fontSize: 15, color: '#333', marginTop: 14, lineHeight: 22 },
});
