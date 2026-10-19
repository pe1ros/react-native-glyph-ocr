# react-native-purely-ocr (working name)

On-device text recognition for React Native, as a [Nitro](https://nitro.margelo.com) module (New Architecture only):
Apple Vision on iOS, PaddleOCR PP-OCRv5 on ONNX Runtime on Android. Russian and the other Cyrillic,
Latin, Arabic, Devanagari, Korean, Thai, Greek, Tamil, Telugu and Chinese packs of PP-OCRv5 on Android; whatever Vision reads on iOS.
Images never leave the device.

The API and its decisions are in `docs/ocr-library-api.md` of the Purely repository; measurements in `docs/spikes/`.

```ts
import { createOcr, recognize, useOcr } from 'react-native-purely-ocr';

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
| `react-native-purely-ocr` | `recognize`, `recognizeText`, `createOcr`, `useOcr`, `prepare`, `isReady`, `getSupportedLanguages`, `configureModels`, `getModelStore`, `OcrError` |
| `react-native-purely-ocr/camera` | `useTextScanner` (VisionCamera 5: waits for a sharp, still frame and recognizes it once), `createFrameMeter`, `viewRectToImageRect`, `imageRectToViewRect`. Needs `react-native-vision-camera` ≥ 5, `react-native-vision-camera-worklets` and `react-native-worklets` |
| `react-native-purely-ocr/dev` | bench helpers: tuned recognizers (threads, pinned cores, ExecuTorch), ML Kit for comparison, camera-like test frames |

On Android, `frame.getNativeBuffer()` of VisionCamera 5.0.11 works only when the app is built with `minSdk` ≥ 26, and
`recognizeFrame` needs Android 10 on the device.

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
| `PurelyOcr_embedPacks=eslav,…` | `gradle.properties` | empty | downloads these packs at build time, checks sha256, packs them into `assets/ocr-models` |
| `PurelyOcr_devMlKit=true` | `gradle.properties` | off | compiles ML Kit Text Recognition (Latin) for `/dev` (+12.5 MB, ML Kit Terms of Service) |
| `PurelyOcr_executorch=auto\|true\|false` | `gradle.properties` | `auto` | compiles the ExecuTorch runtime from `android/executorch` (built by `scripts/ocr-spike/executorch/build-android.sh`; arm64 only) |
| `PurelyOcr_paddleOnIos=1` | `ENV` of `pod install` | off | reserved for PaddleOCR on iOS; not implemented yet, `pod install` stops with an error |

## Notes

- **Thread affinity.** ONNX Runtime ignores `session.intra_op_thread_affinities` on Android. `DevTuning.cpus` pins the
  recognizer's thread before the sessions are created, and ONNX Runtime's pool threads inherit that CPU mask.
- **XNNPACK.** `DevTuning.useXnnpack` crashes ONNX Runtime 1.30 (SIGSEGV in `OrtSession.run`) on the recognizer.
- **Nitro.** The generated code is from nitrogen 0.35.9, the version of `react-native-nitro-modules` in the app. Keep the two equal.
  Two nitrogen limits shaped the spec: an optional `string[]` in a struct does not compile in Swift (so `customWords` belong to
  `createOcr`), and a `UInt64` in a struct does not compile in Kotlin (so `createTestFrame` returns the pointer alone).
- The iOS pod builds its Swift with `-O` even in Debug: the frame meter loops over pixels on every camera frame.

## Licenses

- PP-OCRv5 models and dictionaries: Apache-2.0, PaddlePaddle ([Hugging Face](https://huggingface.co/PaddlePaddle)).
- ONNX Runtime Android: MIT. ExecuTorch: BSD-3-Clause. ML Kit (dev builds only): ML Kit Terms of Service.

## Regenerating the bindings

The bindings in `nitrogen/generated` are generated from `src/specs/*.nitro.ts`. After editing a spec, run from this folder:

```bash
npx nitrogen@0.35.9
```
