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

export default function SheetHeroList() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      <Text style={styles.intro}>
        FormSheet presentation. On iOS this is a true UIKit sheet — on Android
        we get the native-stack sheet style. The hero flies into the sheet body.
      </Text>
      {PHOTOS.slice(0, 4).map((photo) => (
        <TouchableOpacity
          key={photo.id}
          activeOpacity={0.9}
          onPress={() => nav.navigate('SheetHeroDetail', { id: photo.id })}
        >
          <SharedHero
            id={`sheet-${photo.id}`}
            namespace="sheet"
            mode="snapshot"
            duration={380}
            style={styles.thumb}
          >
            <Image source={{ uri: photo.uri }} style={styles.fill} />
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
