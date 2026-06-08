import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function ArcPathDetail() {
  const route = useRoute<RouteProp<RootStackParamList, 'ArcPathDetail'>>();
  const photo = photoById(route.params.id);
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="never"
      contentContainerStyle={styles.container}
    >
      <SharedHero
        id={`arc-${photo.id}`}
        namespace="arc"
        mode="morph"
        motionPath="arc"
        duration={520}
        easing="emphasized"
        style={[styles.hero, { backgroundColor: photo.color }]}
      >
        <Image source={{ uri: photo.uri }} style={styles.fill} />
      </SharedHero>
      <View style={styles.body}>
        <Text style={styles.title}>{photo.title}</Text>
        <Text style={styles.paragraph}>
          The element followed a quadratic bezier curve from its source centre,
          through an offset control point, to the destination centre — the
          Material-style arc motion path. Combined with the "emphasized" easing
          curve, the flight reads as more deliberate than a straight line.
        </Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { paddingBottom: 32 },
  hero: { width: '100%', height: 280, overflow: 'hidden' },
  fill: { width: '100%', height: '100%' },
  body: { padding: 20 },
  title: { fontSize: 22, fontWeight: '700', color: '#111' },
  paragraph: { fontSize: 15, color: '#333', marginTop: 14, lineHeight: 22 },
});
