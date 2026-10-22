import { useEffect, useMemo, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useOcr } from 'react-native-glyph-ocr';
import { type ScanRegion, useTextScanner } from 'react-native-glyph-ocr/camera';
import {
  Camera,
  useCameraDevice,
  useCameraPermission,
} from 'react-native-vision-camera';

/** The scan frame, normalized to the preview. */
const FRAME = { x: 0.08, y: 0.25, width: 0.84, height: 0.35 };

/** `useTextScanner`: waits for a sharp, still frame inside the box and recognizes it once. */
export function CameraScreen() {
  const ocr = useOcr({ languages: ['ru', 'en'] });
  const device = useCameraDevice('back');
  const { hasPermission, requestPermission } = useCameraPermission();
  const [preview, setPreview] = useState<{ width: number; height: number }>();

  const region = useMemo<ScanRegion | undefined>(
    () =>
      preview ? { rect: FRAME, view: preview, resizeMode: 'cover' } : undefined,
    [preview],
  );
  const scanner = useTextScanner({ ocr: ocr.ocr, region });

  useEffect(() => {
    if (!hasPermission) {
      requestPermission();
    }
  }, [hasPermission, requestPermission]);

  if (!hasPermission || device == null) {
    return (
      <View style={styles.center}>
        <Text>
          {device == null ? 'No camera on this device' : 'No camera permission'}
        </Text>
      </View>
    );
  }

  return (
    <View
      style={styles.container}
      onLayout={e => setPreview(e.nativeEvent.layout)}
    >
      <Camera
        style={StyleSheet.absoluteFill}
        device={device}
        outputs={[scanner.frameOutput]}
        isActive={scanner.state !== 'done'}
        // Frames follow the screen, not the gravity sensor: over a label on a table the phone
        // lies almost flat, and the sensor would report it sideways.
        orientationSource="interface"
        resizeMode="cover"
      />
      {preview ? (
        <View
          pointerEvents="none"
          style={[
            styles.frame,
            {
              left: FRAME.x * preview.width,
              top: FRAME.y * preview.height,
              width: FRAME.width * preview.width,
              height: FRAME.height * preview.height,
            },
          ]}
        />
      ) : null}
      <View style={styles.panel}>
        <Text style={styles.state}>
          {ocr.status !== 'ready' ? `models: ${ocr.status}` : scanner.state}
          {scanner.quality
            ? `  sharp ${scanner.quality.sharpness.toFixed(0)} · motion ${scanner.quality.motion.toFixed(3)} · light ${scanner.quality.brightness.toFixed(2)}`
            : ''}
        </Text>
        {scanner.result ? (
          <Text numberOfLines={8} style={styles.result}>
            {scanner.result.text}
          </Text>
        ) : null}
        {scanner.error ? (
          <Text style={styles.result}>{scanner.error.message}</Text>
        ) : null}
        {scanner.state === 'done' || scanner.state === 'error' ? (
          <Pressable
            accessibilityRole="button"
            onPress={scanner.reset}
            style={styles.button}
          >
            <Text style={styles.buttonText}>Scan again</Text>
          </Pressable>
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#000' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  frame: {
    position: 'absolute',
    borderWidth: 2,
    borderColor: '#fff',
    borderRadius: 12,
  },
  panel: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    padding: 16,
    gap: 8,
    backgroundColor: 'rgba(0,0,0,0.6)',
  },
  state: { color: '#fff', fontVariant: ['tabular-nums'] },
  result: { color: '#fff', fontSize: 15 },
  button: {
    backgroundColor: '#fff',
    padding: 12,
    borderRadius: 8,
    alignItems: 'center',
  },
  buttonText: { color: '#000', fontWeight: '600' },
});
