import { ScrollView, StyleSheet, Text, TouchableOpacity } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { SharedHero } from 'react-native-shared-hero';
import { PHOTOS } from '../../data';
import type { RootStackParamList } from '../../navigation';

// Text shared heroes. The list shows each title/subtitle SMALL and on one line;
// the detail shows the SAME strings as a LARGE headline that may wrap to two
// lines. Source and destination therefore have different aspect ratios — the
// case that used to center-crop the flying bitmap and slice the glyphs (a wide
// "Pine Cathedral" rendered mid-flight as a giant "ne Cathed").
//
// `snapshot` mode (the default) now aspect-FITS instead of aspect-FILLS, so the
// text scales uniformly and stays whole, then crossfades to the real (possibly
// re-wrapped) destination layout. No per-screen tweaking required.
export default function TextHeroList() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.container}
    >
      <Text style={styles.intro}>
        Tap a row. The small one-line title flies up and grows into the detail
        headline — even when the destination re-wraps to two lines. Text heroes
        no longer crop mid-flight.
      </Text>
      {PHOTOS.map((photo) => (
        <TouchableOpacity
          key={photo.id}
          activeOpacity={0.7}
          style={styles.row}
          onPress={() => nav.navigate('TextHeroDetail', { id: photo.id })}
        >
          <SharedHero
            id={`text-title-${photo.id}`}
            namespace="text"
            mode="snapshot"
            style={styles.heroWrap}
          >
            <Text style={styles.rowTitle} numberOfLines={1}>
              {photo.title}
            </Text>
          </SharedHero>
          <SharedHero
            id={`text-sub-${photo.id}`}
            namespace="text"
            mode="snapshot"
            style={styles.heroWrap}
          >
            <Text style={styles.rowSubtitle} numberOfLines={1}>
              {photo.subtitle}
            </Text>
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
  row: {
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#e5e5ea',
  },
  // alignSelf:'flex-start' makes each hero shrink-wrap its text, so the captured
  // snapshot is the glyph box (not a full-width row), matching the detail hero.
  heroWrap: { alignSelf: 'flex-start' },
  rowTitle: { fontSize: 17, fontWeight: '600', color: '#111' },
  rowSubtitle: { fontSize: 13, color: '#666', marginTop: 2 },
});
