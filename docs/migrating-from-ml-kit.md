# Migrating from @react-native-ml-kit/text-recognition

The result has the same tree, blocks → lines → elements, so most code keeps working after a few
renames. What you gain: Russian and the other Cyrillic languages on Android, no ML Kit pods on iOS
(the app builds for the Apple Silicon simulator), confidence and angle on every node, EXIF handled
natively, `roi`, typed errors and the New Architecture.

## Install

```sh
npm uninstall @react-native-ml-kit/text-recognition
npm install react-native-glyph-ocr react-native-nitro-modules
cd ios && pod install
```

The app must use the New Architecture, and iOS 16 or later.

## Calls

```ts
// Before
import TextRecognition, { TextRecognitionScript } from '@react-native-ml-kit/text-recognition';
const result = await TextRecognition.recognize(uri, TextRecognitionScript.LATIN);

// After
import { recognize } from 'react-native-glyph-ocr';
const result = await recognize(uri, { languages: ['en'] });
```

`recognize()` caches one instance per language set. For repeated calls, or to download models
before the first photo, create one yourself:

```ts
import { createOcr } from 'react-native-glyph-ocr';

const ocr = createOcr({ languages: ['ru', 'en'] });
await ocr.prepare(); // Android: downloads the model pack once (13.7 MB), then loads it
const result = await ocr.recognize(uri);
```

| ML Kit script | `languages` | Android pack (downloaded on first use) |
|---|---|---|
| `LATIN` | `['en']`, or the actual languages: `['de', 'fr']` | `en` or `latin` |
| `CHINESE` | `['zh-Hans']` or `['zh-Hant']` | `ch` |
| `JAPANESE` | `['ja']` | `ch` |
| `KOREAN` | `['ko']` | `korean` |
| `DEVANAGARI` | `['hi']`, `['mr']`, `['ne']` | `devanagari` |
| — | `['ru', 'en']`, `['uk']`, `['kk']`, `['bg']`, `['ar']`, `['th']`, … | `eslav`, `cyrillic`, `arabic`, `th`, … |

On iOS the languages go to Apple Vision; `getSupportedLanguages()` lists what the device reads.

## Sources

| ML Kit | Here |
|---|---|
| `file://`, path | the same |
| `content://` (Android) | the same |
| `ph://` (iOS) | supported |
| `http(s)://` | **refused** (`unsupported-source`): download to a file first, images never touch the network here |
| — | base64, `data:` URI, react-native-nitro-image `Image`, VisionCamera frames |

## Result

| ML Kit | Here | Note |
|---|---|---|
| `result.text` | `result.text` | blocks joined with `\n`; `readingOrder: 'rows'` joins visual rows instead |
| `block.frame` `{ left, top, width, height }` | `block.pixelBoundingBox` `{ x, y, width, height }` | pixels of the upright image |
| — | `block.boundingBox` | the same box normalized to 0..1 |
| — | `result.image` `{ width, height }` | the size every box refers to |
| `cornerPoints` (pixels) | `cornerPoints` (normalized 0..1) | multiply by `result.image` for pixels |
| — | `confidence`, `angle` | on blocks, lines and elements |
| `recognizedLanguages` | `result.languages` | per result, not per line |
| `block.lines`, `line.elements` | the same | |

If you would rather keep the old shape, an adapter is a few lines:

```ts
import type { OcrResult } from 'react-native-glyph-ocr';

const frame = (b: { x: number; y: number; width: number; height: number }) => ({
  left: b.x,
  top: b.y,
  width: b.width,
  height: b.height,
});

export function toMlKitShape(r: OcrResult) {
  const px = (p: { x: number; y: number }) => ({
    x: p.x * r.image.width,
    y: p.y * r.image.height,
  });
  const node = <T extends { text: string; pixelBoundingBox: any; cornerPoints: any[] }>(n: T) => ({
    text: n.text,
    frame: frame(n.pixelBoundingBox),
    cornerPoints: n.cornerPoints.map(px),
  });
  return {
    text: r.text,
    blocks: r.blocks.map(b => ({
      ...node(b),
      recognizedLanguages: r.languages.map(languageCode => ({ languageCode })),
      lines: b.lines.map(l => ({
        ...node(l),
        recognizedLanguages: r.languages.map(languageCode => ({ languageCode })),
        elements: l.elements.map(node),
      })),
    })),
  };
}
```

## Errors

ML Kit rejects with an untyped error. Here every rejection is an `OcrError` with a `code`
(`source-not-found`, `decode-failed`, `language-not-supported`, `download-failed`, …): see the
README's table.

## App size

ML Kit bundles its Latin model into the APK (about +12.5 MB) and every script you add. Here the
Android models are downloaded per language pack on first use, or embedded with
`GlyphOcr_embedPacks`; ONNX Runtime adds its native library. iOS adds nothing: Vision is part of
the system.
