# react-native-glyph-ocr

On-device text recognition for React Native, as a [Nitro](https://nitro.margelo.com) module (New Architecture only):
Apple Vision on iOS, PaddleOCR PP-OCRv5 on ONNX Runtime on Android. Russian and the other Cyrillic,
Latin, Arabic, Devanagari, Korean, Thai, Greek, Tamil, Telugu and Chinese packs of PP-OCRv5 on Android; whatever Vision reads on iOS.
Images never leave the device.

Not published to npm yet. Install it from this repository by tag:

```json
"react-native-glyph-ocr": "git+ssh://git@github.com/pe1ros/react-native-glyph-ocr.git#v0.2.0"
```

```ts
import { createOcr, recognize, useOcr } from 'react-native-glyph-ocr';

const text = (await recognize('file:///…/label.jpg', { languages: ['ru', 'en'] })).text;

const ocr = createOcr({ languages: ['ru', 'en'] });  // Vision on iOS, the `eslav` pack on Android
await ocr.prepare({ onProgress: p => console.log(p.fraction) });  // download, load, warm up
const result = await ocr.recognize(uri, { roi: { x: 0.1, y: 0.3, width: 0.8, height: 0.4, unit: 'normalized' } });
// result.blocks[].lines[].elements[]: text, confidence, boundingBox (0..1), pixelBoundingBox, cornerPoints, angle
ocr.dispose();
```

## Entry points

| Import | What |
|---|---|
| `react-native-glyph-ocr` | `recognize`, `recognizeText`, `createOcr`, `useOcr`, `prepare`, `isReady`, `getSupportedLanguages`, `configureModels`, `getModelStore`, `OcrError` |
| `react-native-glyph-ocr/camera` | `useTextScanner` (VisionCamera 5: waits for a sharp, still frame and recognizes it once), `createFrameMeter`, `viewRectToImageRect`, `imageRectToViewRect`. Needs `react-native-vision-camera` ≥ 5.2.3, `react-native-vision-camera-worklets` and `react-native-worklets` |
| `react-native-glyph-ocr/dev` | bench helpers: tuned recognizers (threads, pinned cores, ExecuTorch), ML Kit for comparison, camera-like test frames |

On Android, `frame.getNativeBuffer()` of VisionCamera 5.2.3 works only when the app is built with `minSdk` ≥ 26, and
`recognizeFrame` needs Android 10 on the device.

**Use VisionCamera 5.2.1 or later on Android.** Earlier versions can freeze and abort the app while scanning:
`Caused HeapTaskDaemon failure : SuspendAll timeout; remaining threads: … "com.margelo.camera.frame"` (Runnable).
Their bindings come from nitrogen before 0.36.4, which calls JS callbacks through `@FastNative` JNI methods, so ART treats
the camera thread as running Java for the whole `onFrame`. A deadlock follows when three things meet:

- Hermes' background GC thread (`hades`) frees a `Frame` and attaches itself to the JVM
  (`~JHybridFrameSpec` → `AttachCurrentThread`), holding the heap lock;
- `onFrame` allocates and waits for that lock;
- ART's GC waits for the camera thread to suspend.

On the emulator `useTextScanner` hit this in under 4 minutes when `recognizeOptions` changed every second, and keeping
`onFrame` stable did not help, so any frame processor can hit it. nitrogen 0.36.4 dropped `@FastNative` from callbacks
([margelo/nitro#1456](https://github.com/margelo/nitro/issues/1456), fixed by
[#1457](https://github.com/margelo/nitro/pull/1457)), and VisionCamera 5.2.1 and later are built without it.
With VisionCamera 5.2.3 the same test ran 15 minutes without an abort.

These bindings are generated with nitrogen 0.37.1, so the app needs `react-native-nitro-modules` 0.37 and the Nitro
libraries built for it: VisionCamera 5.2.3 or later, `react-native-nitro-image` 0.15.2 or later.

## Models (Android)

`models/manifest.json` lists the PP-OCRv5 packs, pinned to Hugging Face revisions and checked by sha256. Files are stored as
`<sha256>.<ext>` in `noBackupFilesDir/ocr-models` (Application Support on iOS) and downloaded on the first `prepare()`,
or from your own mirror with `configureModels({ baseUrl })`. Dictionaries ship in `models/`.
`node scripts/build-manifest.mjs` rebuilds the manifest and the dictionaries; `--check` verifies they are current.

| Pack | Languages | Download |
|---|---|---|
| `en` | en | 12.7 MB |
| `eslav` | ru, uk, be, en | 12.7 MB |
| `cyrillic` | ru, uk, be, sr-Cyrl, bg, mk, kk, ky, tg, tt, … (33) | 12.9 MB |
| `latin` | de, fr, es, it, pt, pl, cs, tr, vi, … (48, with en) | 12.9 MB |
| `korean`, `arabic`, `devanagari`, `th`, `el`, `ta`, `te`, `ch` | by name, plus en | 12.6–21.3 MB |

The detector (4.8 MB) is shared by all packs and downloaded once.

## Build flags

| Flag | Where | Default | Effect |
|---|---|---|---|
| `GlyphOcr_embedPacks=eslav,…` | `gradle.properties` | empty | downloads these packs at build time, checks sha256, packs them into `assets/ocr-models` |
| `GlyphOcr_devMlKit=true` | `gradle.properties` | off | compiles ML Kit Text Recognition (Latin) for `/dev` (+12.5 MB, ML Kit Terms of Service) |
| `GlyphOcr_executorch=auto\|true\|false` | `gradle.properties` | `auto` | compiles the ExecuTorch runtime from `android/executorch` (built by `scripts/ocr-spike/executorch/build-android.sh`; arm64 only) |
| `GlyphOcr_paddleOnIos=1` | `ENV` of `pod install` | off | reserved for PaddleOCR on iOS; not implemented yet, `pod install` stops with an error |

## Notes

- **Thread affinity.** ONNX Runtime ignores `session.intra_op_thread_affinities` on Android. `DevTuning.cpus` pins the
  recognizer's thread before the sessions are created, and ONNX Runtime's pool threads inherit that CPU mask.
- **XNNPACK.** `DevTuning.useXnnpack` crashes ONNX Runtime 1.30 (SIGSEGV in `OrtSession.run`) on the recognizer.
- **Nitro.** The generated code is from nitrogen 0.37.1, the version of `react-native-nitro-modules` in the app. Keep the two equal.
  Two limits of nitrogen 0.35.9 shaped the spec: an optional `string[]` in a struct does not compile in Swift (so `customWords` belong to
  `createOcr`), and a `UInt64` in a struct does not compile in Kotlin (so `createTestFrame` returns the pointer alone).
- The iOS pod builds its Swift with `-O` even in Debug: the frame meter loops over pixels on every camera frame.

## Licenses

- PP-OCRv5 models and dictionaries: Apache-2.0, PaddlePaddle ([Hugging Face](https://huggingface.co/PaddlePaddle)).
- ONNX Runtime Android: MIT. ExecuTorch: BSD-3-Clause. ML Kit (dev builds only): ML Kit Terms of Service.

## Regenerating the bindings

The bindings in `nitrogen/generated` are generated from `src/specs/*.nitro.ts`. After editing a spec, run from this folder:

```bash
npx nitrogen@0.37.1
```
