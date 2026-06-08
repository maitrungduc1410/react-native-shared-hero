import {
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import type { RootStackParamList } from '../navigation';

type ExampleEntry = {
  route: keyof RootStackParamList;
  title: string;
  description: string;
};

const EXAMPLES: ExampleEntry[] = [
  {
    route: 'BasicImageHero',
    title: 'Basic image hero',
    description:
      'List → detail. The simplest case: image grows into the detail screen.',
  },
  {
    route: 'FlatListHero',
    title: 'FlatList (virtualized)',
    description:
      'Shared hero from a virtualized FlatList — verifies recycling/virtualization is handled.',
  },
  {
    route: 'CardMorph',
    title: 'Card morph (Material container)',
    description:
      'Corner radius, background color and size interpolate together.',
  },
  {
    route: 'ModalHero',
    title: 'Native modal hero',
    description: 'Push a presentation:"modal" screen with a shared element.',
  },
  {
    route: 'TransparentModalHero',
    title: 'Transparent modal hero',
    description: 'The case Reanimated SET still cannot do correctly on iOS.',
  },
  {
    route: 'TabsHero',
    title: 'Tabs → detail hero',
    description: 'A tab screen pushes to a detail with a shared element.',
  },
  {
    route: 'SheetHero',
    title: 'FormSheet hero',
    description: 'Native form sheet on iOS, bottom sheet style on Android.',
  },
  {
    route: 'InPlaceToggle',
    title: 'In-place toggle',
    description: 'No navigation. Tap to morph in the same screen.',
  },
  {
    route: 'SpringVsDuration',
    title: 'Spring vs duration',
    description: 'Side-by-side comparison of the two timing models.',
  },
  {
    route: 'ArcPath',
    title: 'Arc path motion',
    description:
      'Material-y curved flight path between source and destination.',
  },
  {
    route: 'CustomShuttle',
    title: 'Custom shuttle',
    description: 'Render a totally different React component mid-flight.',
  },
  {
    route: 'GestureReturn',
    title: 'Drag-to-dismiss',
    description: 'Gesture-driven interactive return that follows the finger.',
  },
  {
    route: 'MultiStep',
    title: 'Multi-step navigation',
    description:
      'Tap a hero to open a detail, then tap inside to drill deeper — a flying animation at every step.',
  },
  {
    route: 'CoreModalHero',
    title: 'Core Modal (RN)',
    description:
      "Hero into React Native's core <Modal> — a separate UIWindow outside the navigator.",
  },
];

export default function HomeScreen() {
  const navigation =
    useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={styles.container}
      contentInsetAdjustmentBehavior="automatic"
    >
      <Text style={styles.heading}>react-native-shared-hero</Text>
      <Text style={styles.subheading}>
        Router-agnostic, Fabric-native shared element transitions.
      </Text>
      {EXAMPLES.map((e) => (
        <TouchableOpacity
          key={e.route}
          style={styles.row}
          onPress={() => navigation.navigate(e.route as never)}
        >
          <View style={styles.rowText}>
            <Text style={styles.rowTitle}>{e.title}</Text>
            <Text style={styles.rowDescription}>{e.description}</Text>
          </View>
          <Text style={styles.chevron} />
        </TouchableOpacity>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  container: { padding: 16, paddingBottom: 32 },
  heading: { fontSize: 28, fontWeight: '700', marginBottom: 4 },
  subheading: { fontSize: 15, color: '#555', marginBottom: 20 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 14,
    paddingHorizontal: 12,
    borderRadius: 12,
    backgroundColor: '#f5f5f7',
    marginBottom: 10,
  },
  rowText: { flex: 1 },
  rowTitle: { fontSize: 16, fontWeight: '600', color: '#111' },
  rowDescription: { fontSize: 13, color: '#555', marginTop: 4 },
  chevron: { fontSize: 20, color: '#bbb', marginLeft: 12 },
});
