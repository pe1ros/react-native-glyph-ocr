import { useState } from 'react';
import {
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { OcrOverlay, type OcrResult, useOcr } from 'react-native-glyph-ocr';

import { SAMPLE_LABEL_BASE64, SAMPLE_SIZE } from './sample';

const LANGUAGES = ['ru', 'en'];

/** Recognizes the bundled label and draws the line boxes over it. */
export function PhotoScreen() {
  const ocr = useOcr({ languages: LANGUAGES });
  const [result, setResult] = useState<OcrResult>();
  const [error, setError] = useState<string>();
  const [picked, setPicked] = useState<string>();
  const [width, setWidth] = useState(0);
  const view = {
    width,
    height: (width * SAMPLE_SIZE.height) / SAMPLE_SIZE.width,
  };

  const run = async () => {
    setError(undefined);
    setPicked(undefined);
    try {
      setResult(
        await ocr.recognize(
          { base64: SAMPLE_LABEL_BASE64 },
          { diagnostics: true },
        ),
      );
    } catch (e) {
      setError(String(e));
    }
  };

  return (
    <ScrollView contentContainerStyle={styles.content}>
      <Text style={styles.status}>
        {ocr.status}
        {ocr.downloadProgress != null
          ? ` ${Math.round(ocr.downloadProgress * 100)}%`
          : ''}
        {ocr.ocr
          ? ` · ${ocr.ocr.engine}${ocr.ocr.packId ? `/${ocr.ocr.packId}` : ''}`
          : ''}
      </Text>
      {ocr.error ? <Text style={styles.error}>{ocr.error.message}</Text> : null}
      <View onLayout={e => setWidth(e.nativeEvent.layout.width)}>
        <Image
          source={{ uri: `data:image/jpeg;base64,${SAMPLE_LABEL_BASE64}` }}
          style={{ width: view.width, height: view.height }}
        />
        {result ? (
          <OcrOverlay
            result={result}
            resizeMode="contain"
            onPress={node => setPicked(node.text)}
          />
        ) : null}
      </View>
      <Pressable
        accessibilityRole="button"
        disabled={!ocr.isReady}
        onPress={run}
        style={[styles.button, !ocr.isReady && styles.disabled]}
      >
        <Text style={styles.buttonText}>Recognize the label</Text>
      </Pressable>
      {error ? <Text style={styles.error}>{error}</Text> : null}
      {result ? (
        <>
          <Text style={styles.meta}>
            {result.timings.totalMs.toFixed(0)} ms ·{' '}
            {result.blocks.reduce((n, b) => n + b.lines.length, 0)} lines · tap
            a box to pick a line
          </Text>
          {picked ? <Text style={styles.picked}>{picked}</Text> : null}
          <Text selectable style={styles.text}>
            {result.text}
          </Text>
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 12 },
  status: { color: '#555' },
  error: { color: '#b00020' },
  button: {
    backgroundColor: '#222',
    padding: 14,
    borderRadius: 8,
    alignItems: 'center',
  },
  disabled: { opacity: 0.4 },
  buttonText: { color: '#fff', fontWeight: '600' },
  meta: { color: '#555' },
  picked: { fontSize: 16, fontWeight: '600', color: '#b26a00' },
  text: { fontSize: 16, lineHeight: 22 },
});
