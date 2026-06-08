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

export default function GestureReturnList() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      <Text style={styles.intro}>
        Tap an image. In the detail, drag the hero down to dismiss — your finger
        drives the dismiss visual, then the library's auto-flight snaps the hero
        back to its origin in the grid.
      </Text>
      <Text style={styles.note}>
        Note: a fully native gesture-driven progress driver (predictive back on
        Android, interactivePopGestureRecognizer on iOS) is planned for v2 via
        the TurboModule API. This v1 demonstration uses JS-driven drag plus the
        standard mount/unmount auto-flight on release.
      </Text>
      <ScrollViewGrid nav={nav} />
    </ScrollView>
  );
}

function ScrollViewGrid({
  nav,
}: {
  nav: NativeStackNavigationProp<RootStackParamList>;
}) {
  return (
    <>
      {PHOTOS.slice(0, 4).map((photo) => (
        <TouchableOpacity
          key={photo.id}
          activeOpacity={0.9}
          onPress={() => nav.navigate('GestureReturnDetail', { id: photo.id })}
        >
          <SharedHero
            id={`gesture-${photo.id}`}
            namespace="gesture"
            mode="snapshot"
            duration={360}
            style={styles.thumb}
          >
            <Image source={{ uri: photo.uri }} style={styles.fill} />
          </SharedHero>
        </TouchableOpacity>
      ))}
    </>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { padding: 16, paddingBottom: 32 },
  intro: { fontSize: 14, color: '#555', marginBottom: 8 },
  note: {
    fontSize: 12,
    color: '#777',
    backgroundColor: '#f5f5f7',
    padding: 10,
    borderRadius: 10,
    marginBottom: 14,
    lineHeight: 18,
  },
  thumb: {
    width: '100%',
    aspectRatio: 16 / 10,
    borderRadius: 14,
    overflow: 'hidden',
    backgroundColor: '#eee',
    marginBottom: 12,
  },
  fill: { width: '100%', height: '100%' },
});
