import { useState } from 'react';
import {
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  View,
} from 'react-native';

import { runSelfTest } from './selftest';

/** Runs `selftest.ts` on the device. Each line is also logged with the `[selftest]` prefix. */
export function SelfTestScreen() {
  const [lines, setLines] = useState<string[]>([]);
  const [summary, setSummary] = useState<string>();
  const [running, setRunning] = useState(false);
  const [download, setDownload] = useState(false);

  const run = async () => {
    setRunning(true);
    setLines([]);
    setSummary(undefined);
    try {
      const s = await runSelfTest({ download }, line => {
        console.log(`[selftest] ${line}`);
        setLines(l => [...l, line]);
      });
      console.log(`[selftest] ${s}`);
      setSummary(s);
    } catch (e) {
      console.log(`[selftest] crashed: ${String(e)}`);
      setSummary(`crashed: ${String(e)}`);
    } finally {
      setRunning(false);
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.row}>
        <Switch value={download} onValueChange={setDownload} />
        <Text style={styles.flex}>Also download a model pack (~13 MB)</Text>
      </View>
      <Pressable
        accessibilityRole="button"
        disabled={running}
        onPress={run}
        style={[styles.button, running && styles.disabled]}
      >
        <Text style={styles.buttonText}>
          {running ? 'Running…' : 'Run self-test'}
        </Text>
      </Pressable>
      {summary ? (
        <Text testID="selftest-summary" style={styles.summary}>
          {summary}
        </Text>
      ) : null}
      <ScrollView style={styles.flex}>
        {lines.map((l, i) => (
          <Text
            key={i}
            style={[styles.line, l.startsWith('FAIL') && styles.fail]}
          >
            {l}
          </Text>
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 16, gap: 12 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  flex: { flex: 1 },
  button: {
    backgroundColor: '#222',
    padding: 14,
    borderRadius: 8,
    alignItems: 'center',
  },
  disabled: { opacity: 0.4 },
  buttonText: { color: '#fff', fontWeight: '600' },
  summary: { fontWeight: '600' },
  line: {
    fontFamily: Platform.select({ ios: 'Menlo', default: 'monospace' }),
    fontSize: 11,
  },
  fail: { color: '#b00020' },
});
