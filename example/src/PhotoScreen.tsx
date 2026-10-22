import { useState } from 'react';
import {
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { type OcrResult, useOcr } from 'react-native-glyph-ocr';
import { imageRectToViewRect } from 'react-native-glyph-ocr/camera';

import { SAMPLE_LABEL_BASE64, SAMPLE_SIZE } from './sample';

const LANGUAGES = ['ru', 'en'];

/** Recognizes the bundled label and draws the line boxes over it. */
export function PhotoScreen() {
  const ocr = useOcr({ languages: LANGUAGES });
  const [result, setResult] = useState<OcrResult>();
  const [error, setError] = useState<string>();
  const [width, setWidth] = useState(0);
  const view = {
    width,
    height: (width * SAMPLE_SIZE.height) / SAMPLE_SIZE.width,
  };

  const run = async () => {
    setError(undefined);
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
        {result?.blocks
          .flatMap(b => b.lines)
          .map((line, i) => {
            const r = imageRectToViewRect(
              line.boundingBox,
              view,
              result.image,
              'contain',
            );
            return (
              <View
                key={i}
                pointerEvents="none"
                style={[
                  styles.box,
                  {
                    left: r.x * view.width,
                    top: r.y * view.height,
                    width: r.width * view.width,
                    height: r.height * view.height,
                  },
                ]}
              />
            );
          })}
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
            {result.blocks.reduce((n, b) => n + b.lines.length, 0)} lines
          </Text>
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
  box: {
    position: 'absolute',
    borderWidth: 1.5,
    borderColor: '#1e88e5',
    backgroundColor: 'rgba(30,136,229,0.08)',
  },
  button: {
    backgroundColor: '#222',
    padding: 14,
    borderRadius: 8,
    alignItems: 'center',
  },
  disabled: { opacity: 0.4 },
  buttonText: { color: '#fff', fontWeight: '600' },
  meta: { color: '#555' },
  text: { fontSize: 16, lineHeight: 22 },
});
