# Changelog

All notable changes to this package. Versions follow [semantic versioning](https://semver.org);
before 1.0 a minor version may change the API.

## 0.3.1 — unreleased

First release on npm.

- Docs: `availableEngines` lists `paddle` on iOS when the app is built with `GlyphOcr_paddleOnIos=1`.

## 0.3.0

Tagged in git only, not published on npm.

- PaddleOCR on iOS as a build option (`GlyphOcr_paddleOnIos=1`, Expo `paddleOnIos`): the same
  pipeline as Android on onnxruntime-objc, for the languages Vision does not read.
- Upside-down photos: the 8 longest lines are read first; when that reading is not confident, the
  middle of each is read turned 180° too, and the text is read turned only when that reading is
  clearly more confident. Upright text read confidently costs nothing extra. Blocks and rows follow
  the text and the boxes stay on the image. `RecognizeOptions.textlineOrientation`
  (default true). No extra model: the PP-LCNet text line orientation classifier tried first got
  60–70% of the lines of Cyrillic labels right and turned 17 of 61 upright labels upside down.
- `multi` pack: PP-OCRv6 tiny, a 6.2 MB download for Chinese, English and 42 Latin languages;
  detector defaults follow the pack's family.
- `<OcrOverlay>` with `nodeToViewBox`, `imagePointToViewPoint` and `nodesOf`: boxes over the
  photo or the camera preview, rotated with the text, tap to pick a node.
- `useTextScanner({ continuous })`: keeps scanning after a result.
- React Native 0.87 and AGP 9: the Kotlin plugin is applied only when AGP does not provide it,
  `packaging`/`lint` DSL, and release lint is off for the library (AGP 9's lint crashes on the
  nitrogen-generated Kotlin). Tested with React Native 0.85 and 0.87.
- Docs: a comparison with other OCR libraries, a migration guide from
  `@react-native-ml-kit/text-recognition`, and ppu-paddle-ocr in the benchmarks.
- Published as a compiled package: `lib/module` (ES modules) and `lib/typescript` (types) built
  with react-native-builder-bob; the TypeScript sources ship too, for source maps.
- MIT license for the code; `NOTICE` and the Apache-2.0 text for the PP-OCRv5 models and
  dictionaries.
- Expo config plugin: `embedPacks` and `devMlKit` set the Android build flags.
- iOS 16 is now the declared minimum of the pod (Vision revision 3 already needed it).
- The ExecuTorch build scripts moved into the package: `scripts/executorch`.
- Example app with a bundled label, the camera scanner and an on-device self-test of the API.
- Unit tests for errors, sources, the instance cache, language suggestions, view/image geometry and
  the config plugin; CI for lint, types, tests, the package, Android and iOS builds.
- Fixed: on Android, `OcrError.message` no longer carries the Java stack trace that Nitro appends.
- Fixed: the Android library no longer adds React Native codegen output to its sources; in a
  workspace this compiled react-native's own view managers twice.

## 0.2.0

- Bindings generated with nitrogen 0.37.1: needs `react-native-nitro-modules` 0.37,
  VisionCamera ≥ 5.2.3 and react-native-nitro-image ≥ 0.15.2. Fixes the Android scanner abort
  (`SuspendAll timeout`) caused by `@FastNative` callbacks in older Nitro bindings.

## 0.1.0

- First version, installed from git: Apple Vision on iOS, PaddleOCR PP-OCRv5 on ONNX Runtime on
  Android, ML Kit-shaped results, model manifest with sha256 and mirrors, typed errors,
  `useOcr`, `useTextScanner`, `/dev` benchmark helpers.
