# react-native-purely-ocr (spike)

On-device text recognition for the OCR spike, as a [Nitro](https://nitro.margelo.com) module.
Android only: iOS will use Apple Vision, so the module is not linked there.

- **PaddleOCR**: PP-OCRv5 mobile detector plus a Cyrillic recognizer (`eslav` or `cyrillic`), run with ONNX Runtime.
  Pre- and post-processing follow PaddleOCR, with two changes for food labels:
  - curved lines (cans, bottles) are straightened along their centerline;
  - lines are scored by their own pixels, so curved lines are not dropped.
- **ML Kit Text Recognition v2** (Latin script) runs on the same decoded photo for comparison.

The spike screen that uses it lives in `src/spikes/ocr`. The report is in `docs/spikes/paddleocr-android.md`.

## Models

`android/build.gradle` downloads the models into the APK assets at build time. They are pinned by revision and checked by SHA-256.
The real app will download them from our server on first launch instead.

| File | Source | License |
|---|---|---|
| `PP-OCRv5_mobile_det.onnx` | [PaddlePaddle/PP-OCRv5_mobile_det_onnx](https://huggingface.co/PaddlePaddle/PP-OCRv5_mobile_det_onnx) | Apache-2.0 |
| `eslav_PP-OCRv5_mobile_rec.onnx` | [PaddlePaddle/eslav_PP-OCRv5_mobile_rec_onnx](https://huggingface.co/PaddlePaddle/eslav_PP-OCRv5_mobile_rec_onnx) | Apache-2.0 |
| `cyrillic_PP-OCRv5_mobile_rec.onnx` | [PaddlePaddle/cyrillic_PP-OCRv5_mobile_rec_onnx](https://huggingface.co/PaddlePaddle/cyrillic_PP-OCRv5_mobile_rec_onnx) | Apache-2.0 |

`android/src/main/assets/ocr/*.dict.txt` holds each recognizer's `character_dict`, taken from the `inference.yml` next to the model (Apache-2.0, PaddlePaddle).

Other dependencies:
- ONNX Runtime Android (`com.microsoft.onnxruntime:onnxruntime-android`), MIT license.
- ML Kit Text Recognition (`com.google.mlkit:text-recognition`), under the ML Kit Terms of Service.

## Regenerating the bindings

The bindings in `nitrogen/generated` are generated from `src/specs/PurelyOcr.nitro.ts`. After editing the spec, run this from this folder:

```bash
npx nitrogen@0.35.9
```

Keep the nitrogen version the same as `react-native-nitro-modules`.
