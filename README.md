# react-native-glyph-ocr

On-device text recognition for React Native, as a [Nitro](https://nitro.margelo.com) module:
**Apple Vision on iOS, PaddleOCR PP-OCRv5 on Android.** It reads Russian and the other Cyrillic
languages, plus Latin, Arabic, Devanagari, Korean, Thai, Greek, Tamil, Telugu, Chinese and Japanese
scripts on Android, where ML Kit has no Cyrillic. Images never leave the device.

- Result shaped like ML Kit: blocks → lines → words, each with text, confidence, a normalized and
  a pixel box, corner points and angle, all relative to the full upright image.
- Any source: path, `file://`, `content://` (Android), `ph://` (iOS), base64, data URI,
  a [react-native-nitro-image](https://github.com/mrousavy/react-native-nitro-image) `Image`, or a
  [VisionCamera](https://github.com/mrousavy/react-native-vision-camera) 5 frame.
- `roi` crops before recognition; EXIF is applied natively; typed errors, cancelling with
  `AbortSignal`.
- Models are downloaded on first use from pinned Hugging Face revisions and checked by sha256, or
  from your own mirror, or embedded in the app at build time.
- `useTextScanner`: waits for a sharp, still, well-lit camera frame inside your scan box and
  recognizes it once.

Accuracy and speed against ML Kit and Vision: [docs/benchmarks.md](docs/benchmarks.md).

## Requirements

| | |
|---|---|
| React Native | New Architecture. Tested with 0.85 |
| `react-native-nitro-modules` | 0.37 (the bindings are generated with nitrogen 0.37.1) |
| iOS | 16.0 (Vision revision 3) |
| Android | `minSdk` 24; the camera scanner needs `minSdk` 26 and Android 10 on the device (see [Camera](#camera)) |
| Optional | `react-native-vision-camera` ≥ 5.2.3, `react-native-vision-camera-worklets` ≥ 5.2.3 and `react-native-worklets` for `/camera`; `react-native-nitro-image` ≥ 0.15.2 for `Image` sources |

## Installation

```sh
npm install react-native-glyph-ocr react-native-nitro-modules
cd ios && pod install
```

With Expo (a development build, not Expo Go), add the config plugin to `app.json`:

```json
{
  "expo": {
    "plugins": [["react-native-glyph-ocr", { "embedPacks": ["eslav"] }]]
  }
}
```

| Plugin option | Default | Effect |
|---|---|---|
| `embedPacks` | none | Android: packs to download at build time and ship in the APK (the `GlyphOcr_embedPacks` flag) |
| `devMlKit` | `false` | Android: compile ML Kit for `react-native-glyph-ocr/dev` (`GlyphOcr_devMlKit`) |

For the camera scanner on Android, raise `minSdkVersion` to 26 (with `expo-build-properties` in Expo).

## Quick start

```ts
import { createOcr, recognize, useOcr } from 'react-native-glyph-ocr';

// One call: an instance for these languages is created, prepared and cached.
const text = (await recognize('file:///…/label.jpg', { languages: ['ru', 'en'] })).text;

// An instance: languages are fixed per instance (they decide which models are loaded).
const ocr = createOcr({ languages: ['ru', 'en'] }); // Vision on iOS, the `eslav` pack on Android
await ocr.prepare({ onProgress: p => console.log(p.phase, p.fraction) }); // download, load, warm up
const result = await ocr.recognize(uri, {
  roi: { x: 0.1, y: 0.3, width: 0.8, height: 0.4, unit: 'normalized' },
});
for (const block of result.blocks) {
  for (const line of block.lines) {
    console.log(line.text, line.confidence, line.boundingBox);
  }
}
ocr.dispose();
```

In a component:

```tsx
function LabelReader({ uri }: { uri: string }) {
  const ocr = useOcr({ languages: ['ru', 'en'] }); // prepares on mount
  if (ocr.status === 'downloading') return <Progress value={ocr.downloadProgress} />;
  if (ocr.error) return <Text>{ocr.error.code}</Text>;
  return <Button disabled={!ocr.isReady} onPress={() => ocr.recognizeText(uri).then(show)} />;
}
```

## Entry points

| Import | What |
|---|---|
| `react-native-glyph-ocr` | `recognize`, `recognizeText`, `createOcr`, `useOcr`, `prepare`, `isReady`, `getSupportedLanguages`, `configureModels`, `getModelStore`, `OcrError` |
| `react-native-glyph-ocr/camera` | `useTextScanner`, `createFrameMeter`, `viewRectToImageRect`, `imageRectToViewRect` |
| `react-native-glyph-ocr/dev` | benchmark helpers: tuned recognizers, ML Kit for comparison, camera-like test frames. Not for app code: it may change in any release |

## API

### Languages and engines

Languages are BCP-47 tags in priority order. On iOS they become Vision's recognition languages
(`getSupportedLanguages()` lists what this iOS version reads). On Android the first pack of
[`models/manifest.json`](models/manifest.json) that covers all of them is used:

| Pack | Languages | Download |
|---|---|---|
| `en` | en | 12.7 MB |
| `eslav` | ru, uk, be, en | 12.7 MB |
| `cyrillic` | ru, uk, be, sr-Cyrl, bg, mk, mn, kk, ky, tg, tt, ba, … (33, with en) | 12.9 MB |
| `latin` | de, fr, es, it, pt, nl, pl, cs, tr, vi, … (48, with en) | 12.9 MB |
| `arabic`, `devanagari`, `th`, `el`, `ta`, `te` | by name, plus en | 12.6–12.8 MB |
| `korean` | ko, en | 18.3 MB |
| `ch` | zh-Hans, zh-Hant, ja, en | 21.4 MB |

The detector (4.8 MB) is shared by all packs and downloaded once. If no single pack covers the
languages (`['ru', 'de']`), creating the instance throws `language-not-supported` with
`details.suggestion`: one instance per pack.

`engine: 'auto' | 'vision' | 'paddle'` overrides the default (Vision on iOS, Paddle on Android).
Paddle on iOS is not built yet, so `'paddle'` there throws `engine-unavailable`.

### `createOcr(options): Ocr`

| Option | Default | |
|---|---|---|
| `languages` | required | BCP-47 tags |
| `engine` | `'auto'` | |
| `paddlePack` | first covering pack | force a pack, e.g. `'cyrillic'` |
| `threads` | 4 | Paddle inference threads |
| `customWords` | none | Vision: words to prefer with language correction |

`Ocr` has `engine`, `languages`, `packId`, `isReady` (models on disk), `isLoaded` (in memory),
`recognizer` (the native object, for worklets), and:

- `prepare({ onProgress?, signal?, warmUp = true })` — download what is missing, load, warm up;
- `recognize(source, options?)` — prepares first if needed;
- `recognizeText(source, options?)` — the same with `output: 'text'`;
- `dispose()` — frees the models; later calls reject with `disposed`.

`recognize(source, options)` and `recognizeText(source, options)` at the top level take
`languages` (default `['en']`), `engine` and `paddlePack` too, and reuse a small cache of instances.

### Recognition options

| Option | Default | |
|---|---|---|
| `roi` | whole image | `{ x, y, width, height, unit: 'normalized' \| 'pixel', view? }`. Cropped before recognition; result coordinates stay in the full image. With `view: { width, height, resizeMode }` the rect is in view points and mapped onto the image natively |
| `orientation` | `'auto'` | `'auto'` applies EXIF; `'up' \| 'right' \| 'down' \| 'left'` overrides it |
| `recognitionLevel` | `'accurate'` | Vision `.accurate` / `.fast` (`.fast` has no Russian); Paddle `fast` = smaller detector input |
| `usesLanguageCorrection` | `true` | Vision only |
| `minConfidence` | Paddle 0.5, Vision 0 | lines below are dropped |
| `maxImageSide` | 2000 | longer side fed to the engine after the crop; 0 = no limit |
| `readingOrder` | `'blocks'` | `'blocks'`: paragraphs and columns together; `'rows'`: visual rows across the image |
| `output` | `'elements'` | `'text'` skips geometry, `'lines'` skips words |
| `diagnostics` | `false` | fills `result.diagnostics` (runtime, input size, detector/recognizer time) |
| `signal` | none | `AbortSignal`; rejects with `cancelled` |

### Result

```ts
interface OcrResult {
  text: string;            // blocks joined with '\n' ('rows': visual rows)
  blocks: OcrBlock[];      // empty with output: 'text'
  image: { width: number; height: number }; // the full upright source, whatever the roi
  engine: 'vision' | 'paddle';
  languages: string[];
  timings: { decodeMs: number; recognizeMs: number; totalMs: number };
  diagnostics?: OcrDiagnostics;
}
// OcrBlock → lines: OcrLine[] → elements: OcrElement[] (words). Each node has:
//   text, confidence (0..1), boundingBox (0..1 of `image`, top-left origin),
//   pixelBoundingBox, cornerPoints (TL, TR, BR, BL), angle (degrees, clockwise)
```

Vision has no per-word confidence: words repeat their line's.

### Errors

Every rejection is an `OcrError` with a `code`, a `message` and sometimes `details`:

| Code | When |
|---|---|
| `unsupported-source` | the source kind is not supported here: `http(s)://`, `ph://` on Android, `content://` on iOS |
| `source-not-found` | the file, content URI or Photos asset does not exist |
| `source-permission-denied` | no permission to read the source |
| `decode-failed` | not an image, or a corrupt one |
| `invalid-argument` | bad options: ROI outside the image, empty language list, `zh` without a script |
| `language-not-supported` | no pack covers the languages, or `fast` for a language only `accurate` reads |
| `engine-unavailable` | the engine is not compiled in, or the OS is too old |
| `models-not-ready` | models are missing and `source: 'embedded'` forbids downloading |
| `download-failed`, `checksum-mismatch`, `insufficient-storage` | model download |
| `model-load-failed` | the runtime cannot load a model file |
| `frame-unsupported` | a camera buffer the module cannot read (see [Camera](#camera)) |
| `cancelled` | the `AbortSignal` fired |
| `out-of-memory`, `disposed`, `internal` | |

### `useOcr(options)`

`createOcr` options plus `autoPrepare` (default `true`) and `warmUp` (default `true`). Returns
`{ status, isReady, downloadProgress, error, recognize, recognizeText, prepare, ocr }`, where
`status` is `'idle' | 'downloading' | 'loading' | 'ready' | 'error'`. Instances are shared between
components with the same options and kept loaded while mounted.

### Models

```ts
import { configureModels, getModelStore, isReady, prepare } from 'react-native-glyph-ocr';

await configureModels({
  baseUrl: 'https://cdn.example.com/ocr-models', // files at <baseUrl>/<path from the manifest>
  headers: { Authorization: '…' },
  source: 'embedded-or-remote', // or 'remote', 'embedded'
});
await prepare(['ru', 'en'], { onProgress: p => setProgress(p.fraction) }); // download only
isReady('ru'); // true when nothing has to be downloaded (always true for Vision)
await getModelStore().remove(['eslav']);
await getModelStore().prune(); // deletes files no pack of the manifest uses
```

- Files are stored by sha256 in Application Support (iOS, excluded from backup) or
  `noBackupFilesDir` (Android), so changing the mirror does not download again.
- Downloads resume after an interruption (`Range` and a `.part` file), are verified, then renamed
  atomically. Concurrent `prepare` calls share one download.
- A mirror is just a copy of the files under the same paths as `path` in
  [`models/manifest.json`](models/manifest.json). `configureModels({ manifestUrl })` loads a
  manifest of your own.
- Dictionaries ship in the package (1–74 KB each); only the ONNX models are downloaded.

### Camera

```tsx
import { useOcr } from 'react-native-glyph-ocr';
import { useTextScanner } from 'react-native-glyph-ocr/camera';
import { Camera, useCameraDevice } from 'react-native-vision-camera';

function Scanner() {
  const ocr = useOcr({ languages: ['ru', 'en'] });
  const device = useCameraDevice('back');
  const [view, setView] = useState<{ width: number; height: number }>();
  const scanner = useTextScanner({
    ocr: ocr.ocr,
    region: view && { rect: { x: 0.1, y: 0.3, width: 0.8, height: 0.3 }, view, resizeMode: 'cover' },
    accept: r => r.text.length > 20, // return false to keep scanning
    onResult: r => console.log(r.text),
  });
  return (
    <View style={{ flex: 1 }} onLayout={e => setView(e.nativeEvent.layout)}>
      <Camera
        style={StyleSheet.absoluteFill}
        device={device!}
        outputs={[scanner.frameOutput]}
        isActive={scanner.state !== 'done'}
        orientationSource="interface"
        resizeMode="cover"
      />
      <Text>{scanner.state}</Text>
    </View>
  );
}
```

- `state`: `'idle' | 'searching' | 'too-dark' | 'hold-still' | 'recognizing' | 'done' | 'error'`;
  `quality` reports sharpness, motion and brightness about 4 times a second; `reset()` scans again.
- Thresholds (`minSharpness`, `relativeSharpness`, `maxMotion`, `minBrightness`, `stableMs`) have
  measured defaults. `photoOutput` takes a full photo once the frame is good, instead of using the
  video frame: slower, but better for a whole label.
- Use `orientationSource="interface"`: over a label on a table the phone lies almost flat, and the
  gravity sensor would turn the frames sideways.
- For a scanner of your own, call `ocr.recognizer.recognizeFrame(frame.getNativeBuffer().pointer,
  frame.orientation, options)` from a VisionCamera async runner, and `createFrameMeter()` for the
  frame quality. The module does not link VisionCamera natively.

**Android.** VisionCamera returns the frame's `HardwareBuffer` only when the app is built with
`minSdk` 26 or higher, and `recognizeFrame` needs Android 10 on the device; otherwise the scanner
reports `frame-unsupported`. Use VisionCamera 5.2.1 or later: earlier versions are built with
nitrogen before 0.36.4, whose `@FastNative` callbacks can deadlock with ART's garbage collector
while scanning (`SuspendAll timeout … "com.margelo.camera.frame"`,
[margelo/nitro#1456](https://github.com/margelo/nitro/issues/1456)).

## Build flags

| Flag | Where | Default | Effect |
|---|---|---|---|
| `GlyphOcr_embedPacks=eslav,…` | `android/gradle.properties` | empty | downloads these packs at build time, checks sha256, packs them uncompressed into `assets/ocr-models` |
| `GlyphOcr_devMlKit=true` | `android/gradle.properties` | off | compiles ML Kit Text Recognition (Latin) for `/dev` (+12.5 MB, ML Kit Terms of Service) |
| `GlyphOcr_executorch=auto\|true\|false` | `android/gradle.properties` | `auto` | compiles the ExecuTorch runtime from `android/executorch` of this package, built by [`scripts/executorch/build-android.sh`](scripts/executorch/build-android.sh) (arm64 only). Selected in `/dev` only |
| `GlyphOcr_paddleOnIos=1` | env of `pod install` | off | reserved for PaddleOCR on iOS; not implemented, `pod install` stops with an error |

## Platform differences

| | iOS | Android |
|---|---|---|
| Engine | Vision `VNRecognizeTextRequest`, revision 3 | PaddleOCR PP-OCRv5 mobile on ONNX Runtime 1.30 |
| Languages | what the iOS version reads (16 on iOS 16) | the packs above |
| Model size | 0, part of iOS | 12.7 MB per pack, downloaded or embedded |
| Library size | 0 | ONNX Runtime (see [docs/benchmarks.md](docs/benchmarks.md#app-size)) |
| Model version | changes with iOS (iOS 17–18 have an older Cyrillic model) | pinned by sha256 |
| Speed, a cropped ingredients list | 0.15 s, iPhone 13 Pro Max | 0.9–1.1 s, Pixel 6a |
| Rotated text | reads it, including text along an arc | up to ±45° and vertical; not upside down |
| Sources | `ph://`, no `content://` | `content://`, no `ph://` |
| Simulator / emulator | works; texts differ from a device (no Neural Engine) | works; speed is not representative |

## Privacy

Recognition runs on the device; the module never sends images anywhere, and `http(s)` image URLs are
refused on purpose. On Android it downloads model files: from Hugging Face by default, or from your
`baseUrl`. There is no telemetry.

## Example app

[`example/`](example) recognizes a bundled label, runs the camera scanner and has a self-test of the
whole API that runs on a device or simulator. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT for the code. The PP-OCRv5 models and dictionaries are Apache-2.0 (PaddlePaddle Authors); ONNX
Runtime is MIT; ExecuTorch (optional) is BSD-3-Clause; ML Kit (optional, `/dev` only) is under the
ML Kit Terms of Service. See [NOTICE](NOTICE).
