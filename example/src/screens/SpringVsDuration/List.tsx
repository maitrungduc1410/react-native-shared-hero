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

const PHOTO = PHOTOS[1]!;

export default function SpringVsDurationList() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      <Text style={styles.intro}>
        Same hero element, two timing models. Tap each thumbnail to see the
        flight in spring vs duration.
      </Text>
      <View style={styles.row}>
        <Pressable
          style={styles.col}
          onPress={() =>
            nav.navigate('SpringVsDurationDetail', {
              id: PHOTO.id,
              spring: false,
            })
          }
        >
          <SharedHero
            id={`svd-duration`}
            namespace="svd-duration"
            mode="morph"
            duration={360}
            style={styles.thumb}
          >
            <Image source={{ uri: PHOTO.uri }} style={styles.fill} />
          </SharedHero>
          <Text style={styles.label}>Duration · 360 ms</Text>
        </Pressable>
        <Pressable
          style={styles.col}
          onPress={() =>
            nav.navigate('SpringVsDurationDetail', {
              id: PHOTO.id,
              spring: true,
            })
          }
        >
          <SharedHero
            id={`svd-spring`}
            namespace="svd-spring"
            mode="morph"
            spring={{ damping: 16, stiffness: 200, mass: 1 }}
            style={styles.thumb}
          >
            <Image source={{ uri: PHOTO.uri }} style={styles.fill} />
          </SharedHero>
          <Text style={styles.label}>Spring · k=200, ζ=16</Text>
        </Pressable>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { padding: 16, paddingBottom: 32 },
  intro: { fontSize: 14, color: '#555', marginBottom: 16 },
  row: { flexDirection: 'row', gap: 12 },
  col: { flex: 1 },
  thumb: {
    width: '100%',
    aspectRatio: 1,
    borderRadius: 16,
    overflow: 'hidden',
    backgroundColor: '#eee',
  },
  fill: { width: '100%', height: '100%' },
  label: { marginTop: 8, fontSize: 13, color: '#444', textAlign: 'center' },
});
