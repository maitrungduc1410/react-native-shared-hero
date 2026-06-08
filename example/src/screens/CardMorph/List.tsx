import {
  Image,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { SharedHero } from 'react-native-shared-hero';
import { PHOTOS } from '../../data';
import type { RootStackParamList } from '../../navigation';

export default function CardMorphList() {
  const navigation =
    useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      <Text style={styles.intro}>
        Container transform — corner radius, background and bounds animate
        together. Tap a card.
      </Text>
      {PHOTOS.map((photo) => (
        <TouchableOpacity
          key={photo.id}
          activeOpacity={0.92}
          onPress={() =>
            navigation.navigate('CardMorphDetail', { id: photo.id })
          }
        >
          <SharedHero
            id={`card-${photo.id}`}
            namespace="card"
            mode="morph"
            duration={420}
            style={[styles.card, { backgroundColor: photo.color }]}
          >
            <View style={styles.cardInner}>
              <Image source={{ uri: photo.uri }} style={styles.thumb} />
              <View style={styles.cardText}>
                <Text style={styles.title}>{photo.title}</Text>
                <Text style={styles.subtitle}>{photo.subtitle}</Text>
              </View>
            </View>
          </SharedHero>
        </TouchableOpacity>
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
    marginBottom: 14,
  },
  cardInner: { flex: 1, flexDirection: 'row', alignItems: 'center' },
  thumb: { width: 110, height: 110 },
  cardText: { flex: 1, padding: 14 },
  title: { fontSize: 16, fontWeight: '700', color: '#fff' },
  subtitle: { fontSize: 13, color: 'rgba(255,255,255,0.85)', marginTop: 2 },
});
