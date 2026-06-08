import { useEffect, useRef } from 'react';
import {
  Animated,
  Image,
  PanResponder,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useNavigation, useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import { SharedHero } from 'react-native-shared-hero';
import { photoById } from '../../data';
import type { RootStackParamList } from '../../navigation';

const DISMISS_THRESHOLD = 120;

export default function GestureReturnDetail() {
  const route =
    useRoute<RouteProp<RootStackParamList, 'GestureReturnDetail'>>();
  const nav = useNavigation();
  const photo = photoById(route.params.id);

  // Drag offsets are applied to the `Animated.View` that WRAPS the SharedHero
  // (not by swapping the SharedHero out). Keeping the hero mounted means that
  // when the user releases past the threshold and we call `goBack()`, the
  // library's back-flight has a live source view to capture from — and because
  // `convert(_:to:window)` honours the parent's transform, the flight starts
  // from the dragged position, not the original layout position. This is what
  // produces the "the finger threw the hero, then it slingshots back into the
  // grid tile" feel.
  const translateY = useRef(new Animated.Value(0)).current;
  const scale = translateY.interpolate({
    inputRange: [0, 300],
    outputRange: [1, 0.6],
    extrapolate: 'clamp',
  });

  const panResponder = useRef(
    PanResponder.create({
      // Only claim the responder on a deliberate DOWNWARD drag. Without the
      // `g.dy > 8` guard, the user's vertical scrolling would steal the
      // responder from the ScrollView and feel janky.
      onMoveShouldSetPanResponder: (_, g) => g.dy > 8,
      onPanResponderMove: (_, g) => {
        if (g.dy > 0) translateY.setValue(g.dy);
      },
      onPanResponderRelease: (_, g) => {
        if (g.dy > DISMISS_THRESHOLD) {
          // Leave translateY at its current value so the source frame the
          // library captures matches the visible position — the back-flight
          // will slingshot the hero from the dragged position back to its
          // origin tile in the list.
          nav.goBack();
        } else {
          Animated.spring(translateY, {
            toValue: 0,
            useNativeDriver: true,
            bounciness: 4,
          }).start();
        }
      },
      onPanResponderTerminate: () => {
        Animated.spring(translateY, {
          toValue: 0,
          useNativeDriver: true,
        }).start();
      },
    })
  ).current;

  useEffect(() => {
    return () => {
      translateY.stopAnimation();
    };
  }, [translateY]);

  return (
    // A plain View — NOT a ScrollView. On iOS a ScrollView's native pan
    // gesture recognizer (it bounces at offset 0) wins the downward drag
    // and the JS `PanResponder` below never receives the move/release, so
    // `goBack()` is never called and the screen won't dismiss (Android's
    // responder negotiation lets the PanResponder win, which masked this).
    // The content fits on screen, so we don't need scrolling here.
    <View style={styles.scroll}>
      <Animated.View
        {...panResponder.panHandlers}
        style={[styles.heroOuter, { transform: [{ translateY }, { scale }] }]}
      >
        <SharedHero
          id={`gesture-${photo.id}`}
          namespace="gesture"
          mode="snapshot"
          duration={360}
          style={styles.heroWrap}
        >
          <Image source={{ uri: photo.uri }} style={styles.fill} />
        </SharedHero>
      </Animated.View>
      <View style={styles.body}>
        <Text style={styles.title}>{photo.title}</Text>
        <Text style={styles.paragraph}>
          Drag the image down. Past the threshold, the screen pops and the
          shared hero animates back into its origin tile from wherever your
          finger released it. Under the threshold, it springs back.
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#fff' },
  heroOuter: { width: '100%' },
  heroWrap: {
    width: '100%',
    aspectRatio: 16 / 10,
    backgroundColor: '#eee',
    overflow: 'hidden',
  },
  fill: { width: '100%', height: '100%' },
  body: { padding: 20 },
  title: { fontSize: 22, fontWeight: '700', color: '#111' },
  paragraph: { fontSize: 15, color: '#333', marginTop: 14, lineHeight: 22 },
});
