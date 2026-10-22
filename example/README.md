# react-native-glyph-ocr example

Three tabs:

- **Photo** recognizes a bundled label (Russian and English) and draws the line boxes over it.
- **Camera** runs `useTextScanner` from `react-native-glyph-ocr/camera` with VisionCamera 5.
- **Self-test** checks the whole public API on the device and prints `N failed of M`. The same
  lines go to `<benchDir>/out/selftest.txt` (`getOcrDevTools().benchDir`).

The Android build embeds the `eslav` pack (`GlyphOcr_embedPacks=eslav` in
`android/gradle.properties`), so the app works offline; the self-test can also download the
`latin` (Android) or `en` (iOS) pack.

From the repository root:

```sh
yarn
yarn example start
yarn example ios       # or: yarn example android
```

The iOS project needs `pod install` in `example/ios` first (`bundle exec pod install`).
