# Benchmarks

Measured in October 2026 on food labels, the job this module was built for: reading the
ingredients list on packaging in Russian and English.

## Data set

- **8 labels photographed with an iPhone** (12 MP, the whole label in the frame): sauces in bottles,
  jam in a jar, cream, tinned tuna, cottage cheese in a crumpled bag, milk, soy sauce on a dark label.
- **The same 8 photos cropped to the ingredients list**, the way an app lets the user frame it.
- **16 label photos from Open Food Facts** (taken by shoppers, already cropped to the ingredients):
  foil, film, thermal print, text along an arc, curved jars. 268 ingredients and 45 E-numbers in
  total.

The reference text was written out by hand from each photo. A recognized ingredient counts when it
matches the reference with at most one typo per 10 letters. Every photo is turned by EXIF and scaled
to 2000 px on the longer side, the module's default.

## Accuracy

Share of ingredients read, with typos allowed: whole photos / cropped photos / Open Food Facts.

| Engine | Platform | Ingredients | E-numbers (after normalizing Cyrillic «Е») |
|---|---|---|---|
| Apple Vision, revision 3, `accurate` | iOS 26 (iPhone 13 Pro Max, macOS 26.1 for the full runs) | **90% / 97% / 82%** | 60% |
| PaddleOCR PP-OCRv5 mobile, `eslav` pack (this module) | Android (Pixel 6a) | **77% / 83% / 77%** | 60% |
| ML Kit Text Recognition v2, Latin (`/dev`, for comparison) | Android (Pixel 6a) | 20% / 13% / 28% | — |

- ML Kit has no Cyrillic model: it reads Russian as Latin look-alikes.

### Against ppu-paddle-ocr

[ppu-paddle-ocr](https://github.com/PT-Perkasa-Pilar-Utama/ppu-paddle-ocr) 6.6.1 runs the same
PP-OCRv5 `eslav` weights through a TypeScript pipeline. Measured on a Mac (ONNX Runtime 1.30, CPU)
with its defaults, on the same photos, turned by EXIF and scaled to 2000 px:

| | Whole / cropped / Open Food Facts | E-numbers, raw / normalized | Photos with no text |
|---|---|---|---|
| This package, `eslav` | **77% / 83% / 77%** | **51% / 60%** | 0 |
| ppu-paddle-ocr, `eslav`, `per-line` (default) | 73% / 80% / 63% | 31% / 36% | 7 of 61 |
| ppu-paddle-ocr, `eslav`, `per-box` | 80% / 83% / 68% | 49% / 53% | 1 of 61 |
| ppu-paddle-ocr, `cyrillic` | 77% / 83% / 62% | 36% / 36% | 5 of 61 |

The recognizer is the same; the difference is the line finder. ppu takes every pixel above zero on
the detector's map, with no threshold, box score or unclip, and crops axis-aligned boxes, so dense,
tilted or curved text merges into boxes several lines tall that the recognizer then drops. It does
not straighten curved lines.
- With PaddleOCR and ML Kit together, 67% of the E-numbers are read; ignoring suffixes
  (E450 for E450iii), 78%.
- The module straightens curved lines along their centre line and scores a line by its own pixels.
  On the 8 whole photos this gave 72% of the ingredients instead of 66% with PaddleOCR's stock
  post-processing, and the median character error rate fell from 31% to 14% (same models).
- Vision's text depends on the iOS version: iOS 17.2–18.2 ship an older Cyrillic model, and the
  simulator computes slightly different text than a device.

## Speed

Recognition of the photo, decoding included, after the warm-up `prepare()` does.

| | Cropped ingredients | Whole label |
|---|---|---|
| Vision, iPhone 13 Pro Max | **0.15 s** | — |
| PaddleOCR + ONNX Runtime, Pixel 6a (Tensor G1), 4 threads | **0.87 s** cold, 1.1 s warm; 90% of photos under 1.8 s | 3.0 s + 0.46 s to decode 12 MP |
| PaddleOCR + ONNX Runtime, Pixel 6a pinned to its Cortex-A55 cores (an estimate of a budget phone) | 2.9 s; 90% under 5.0 s | 8.0 s |
| PaddleOCR + ExecuTorch (XNNPACK), the same A55 cores | 25–30% faster than ONNX Runtime | |

- First call: Vision loads its models in about 0.5 s; Paddle loads in 0.2–0.8 s (ExecuTorch 0.08 s)
  and warms up in 0.6–2.3 s.
- On the big cores ONNX Runtime and ExecuTorch run at the same speed. ExecuTorch is selectable in
  `/dev` only until it is measured on a real budget phone.

## App size

| | Size |
|---|---|
| Vision (iOS) | 0, part of the system |
| PaddleOCR models, one pack (Android) | 12.7 MB download (detector 4.8 + recognizer 7.9), or embedded with `GlyphOcr_embedPacks` |
| ONNX Runtime 1.30 (Android, the Maven AAR) | `libonnxruntime.so` 33 MB per ABI (arm64-v8a), stored uncompressed |
| ExecuTorch, own minimal build (Android, arm64) | 1.7 MB (0.69 MB gzip) |
| ML Kit Latin with its bundled model (`/dev` only) | +12.5 MB |

All native libraries are aligned for 16 KB pages, as Google Play requires.
