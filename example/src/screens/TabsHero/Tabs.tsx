import { useState } from 'react';
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

const TAB_NAMES = ['Photos', 'Favorites', 'Saved'] as const;

export default function TabsHeroRoot() {
  const [tab, setTab] = useState<(typeof TAB_NAMES)[number]>('Photos');
  const nav = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  const pool =
    tab === 'Photos'
      ? PHOTOS
      : tab === 'Favorites'
        ? PHOTOS.slice(0, 3)
        : PHOTOS.slice(2);
  return (
    <View style={styles.root}>
      <View style={styles.tabBar}>
        {TAB_NAMES.map((name) => (
          <Pressable
            key={name}
            onPress={() => setTab(name)}
            style={[styles.tab, tab === name && styles.tabActive]}
          >
            <Text
              style={[styles.tabLabel, tab === name && styles.tabLabelActive]}
            >
              {name}
            </Text>
          </Pressable>
        ))}
      </View>
      <ScrollView contentContainerStyle={styles.scrollContent}>
        <Text style={styles.intro}>
          Custom in-screen tabs (no nav library tab dependency). Tap a card to
          push to a stack detail — the shared element flies even though the
          trigger was inside a tab pane.
        </Text>
        {pool.map((photo) => (
          <Pressable
            key={photo.id}
            onPress={() => nav.navigate('TabsHeroDetail', { id: photo.id })}
          >
            <SharedHero
              id={`tabs-${photo.id}`}
              namespace="tabs"
              mode="morph"
              duration={400}
              style={[styles.card, { backgroundColor: photo.color }]}
            >
              <View style={styles.cardInner}>
                <Image source={{ uri: photo.uri }} style={styles.thumb} />
                <View style={styles.cardText}>
                  <Text style={styles.cardTitle}>{photo.title}</Text>
                  <Text style={styles.cardSubtitle}>{photo.subtitle}</Text>
                </View>
              </View>
            </SharedHero>
          </Pressable>
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#fff' },
  tabBar: {
    flexDirection: 'row',
    paddingHorizontal: 16,
    paddingTop: 12,
    gap: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#ddd',
  },
  tab: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 999,
    backgroundColor: '#f1f1f3',
    marginBottom: 10,
  },
  tabActive: { backgroundColor: '#111' },
  tabLabel: { fontSize: 13, fontWeight: '600', color: '#444' },
  tabLabelActive: { color: '#fff' },
  scrollContent: { padding: 16 },
  intro: { fontSize: 14, color: '#555', marginBottom: 12 },
  card: {
    width: '100%',
    height: 100,
    borderRadius: 16,
    overflow: 'hidden',
    marginBottom: 12,
  },
  cardInner: { flex: 1, flexDirection: 'row', alignItems: 'center' },
  thumb: { width: 100, height: 100 },
  cardText: { flex: 1, padding: 14 },
  cardTitle: { fontSize: 15, fontWeight: '700', color: '#fff' },
  cardSubtitle: { fontSize: 12, color: 'rgba(255,255,255,0.85)', marginTop: 2 },
});
