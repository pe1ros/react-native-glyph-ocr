# Changelog

All notable changes to this package. Versions follow [semantic versioning](https://semver.org);
before 1.0 a minor version may change the API.

## 0.3.0 — unreleased

First release on npm.

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
