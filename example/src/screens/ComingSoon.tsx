import { StyleSheet, Text, View } from 'react-native';

export default function ComingSoon({ phase }: { phase: string }) {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Coming up</Text>
      <Text style={styles.body}>
        This example is delivered in {phase} of the implementation plan.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 32,
  },
  title: { fontSize: 22, fontWeight: '700', color: '#111', marginBottom: 8 },
  body: { fontSize: 15, color: '#555', textAlign: 'center', lineHeight: 22 },
});
