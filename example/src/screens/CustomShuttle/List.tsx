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

export default function CustomShuttleList() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      <Text style={styles.intro}>
        With `fadeMode="through"` the source fades out, then the destination's
        totally different layout fades in — Flutter's flightShuttleBuilder,
        without the JSX gymnastics.
      </Text>
      {PHOTOS.slice(0, 3).map((photo) => (
        <Pressable
          key={photo.id}
          onPress={() => nav.navigate('CustomShuttleDetail', { id: photo.id })}
        >
          <SharedHero
            id={`shuttle-${photo.id}`}
            namespace="shuttle"
            mode="morph"
            fadeMode="through"
            duration={520}
            easing="emphasized"
            style={[styles.card, { backgroundColor: photo.color }]}
          >
            <View style={styles.cardContent}>
              <Image source={{ uri: photo.uri }} style={styles.thumb} />
              <Text style={styles.label}>{photo.title}</Text>
            </View>
          </SharedHero>
        </Pressable>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { padding: 16, paddingBottom: 32 },
  intro: { fontSize: 14, color: '#555', marginBottom: 16 },
  card: {
    width: '100%',
    height: 110,
    borderRadius: 18,
    overflow: 'hidden',
    marginBottom: 12,
  },
  cardContent: { flex: 1, flexDirection: 'row', alignItems: 'center' },
  thumb: { width: 110, height: 110 },
  label: {
    flex: 1,
    padding: 14,
    color: '#fff',
    fontSize: 15,
    fontWeight: '600',
  },
});
