import { Image, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function SpringVsDurationDetail() {
  const route =
    useRoute<RouteProp<RootStackParamList, 'SpringVsDurationDetail'>>();
  const photo = photoById(route.params.id);
  const isSpring = route.params.spring;
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="never"
      contentContainerStyle={styles.container}
    >
      {isSpring ? (
        <SharedHero
          id={`svd-spring`}
          namespace="svd-spring"
          mode="morph"
          spring={{ damping: 16, stiffness: 200, mass: 1 }}
          style={styles.hero}
        >
          <Image source={{ uri: photo.uri }} style={styles.fill} />
        </SharedHero>
      ) : (
        <SharedHero
          id={`svd-duration`}
          namespace="svd-duration"
          mode="morph"
          duration={360}
          style={styles.hero}
        >
          <Image source={{ uri: photo.uri }} style={styles.fill} />
        </SharedHero>
      )}
      <View style={styles.body}>
        <Text style={styles.title}>
          {isSpring ? 'Spring timing' : 'Duration timing'}
        </Text>
        <Text style={styles.paragraph}>
          {isSpring
            ? 'Spring uses UISpringTimingParameters on iOS and SpringAnimation on Android — physical, overshoots gently, settles into place.'
            : 'Duration uses a fixed time with an easing curve. Predictable, snappy, no overshoot.'}
        </Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { paddingBottom: 32 },
  hero: { width: '100%', aspectRatio: 1, backgroundColor: '#eee' },
  fill: { width: '100%', height: '100%' },
  body: { padding: 20 },
  title: { fontSize: 22, fontWeight: '700', color: '#111' },
  paragraph: { fontSize: 15, color: '#333', marginTop: 14, lineHeight: 22 },
});
