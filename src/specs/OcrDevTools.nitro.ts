import type { HybridObject, UInt64 } from 'react-native-nitro-modules';

import type {
  FrameOrientation,
  OcrEngine,
  OcrRecognizer,
  OcrResult,
} from './Ocr.nitro';

export interface DeviceSummary {
  manufacturer: string;
  /** On iOS the model identifier, e.g. `iPhone14,3`. */
  model: string;
  /** SoC model on Android 12+, otherwise the board/hardware name (on iOS the board, e.g. `D64AP`). */
  soc: string;
  /** `Android 16 (API 36)`, `iOS 26.0`. */
  osVersion: string;
  cpuCores: number;
  /** Max frequency of every core, MHz. Empty on iOS. */
  maxCpuFreqsMHz: number[];
  totalRamMb: number;
  abi: string;
}

/** Paddle inference runtime. ONNX Runtime is the default until ExecuTorch wins an A/B run on a budget phone. */
export type PaddleRuntimeKind = 'onnxruntime' | 'executorch';

/** Benchmark-only knobs. Not part of the public API. */
export interface DevTuning {
  /** Paddle inference threads; 0 = the runtime's default. */
  threads?: number;
  /** ONNX Runtime's XNNPACK execution provider. Crashes ONNX Runtime 1.30 on the recognizer. */
  useXnnpack?: boolean;
  /** Pin the engine to these cores (0-based), one thread per core. Android only. */
  cpus?: number[];
  /** Default `onnxruntime`. `executorch` needs a build with ExecuTorch and `program`. */
  runtime?: PaddleRuntimeKind;
  /**
   * ExecuTorch: absolute path of one fused `.pte` program with `detect` and `recognize`
   * (scripts/ocr-spike/executorch). The dictionary still comes from the pack.
   */
  program?: string;
}

/**
 * A buffer made by `createTestFrame`. The pointer is returned on its own: nitrogen 0.35.9 cannot
 * put a `UInt64` into a struct on Android (two Kotlin constructors with the same JVM signature).
 */
export interface TestFrameInfo {
  /** Size of the buffer as stored, before the orientation turns it upright. */
  width: number;
  height: number;
  /** `yuv-420-biplanar-full` (iOS), `yuv-420` or `rgba` (Android). */
  pixelFormat: string;
}

/** Bench helpers of the OCR spike. Imported only from `react-native-purely-ocr/dev`. */
export interface OcrDevTools
  extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  /** `<app external files>/ocr-bench` on Android, `<Documents>/ocr-bench` on iOS, with `in/` and `out/`. */
  readonly benchDir: string;
  /** Absolute paths of the JPEG/PNG/HEIC/WebP files in `dir`, sorted by name. */
  listImages(dir: string): string[];
  writeText(path: string, content: string): void;
  getDeviceSummary(): DeviceSummary;

  createTunedRecognizer(
    engine: OcrEngine,
    languages: string[],
    packId: string | undefined,
    tuning: DevTuning,
  ): OcrRecognizer;

  /** Android builds with `PurelyOcr_devMlKit=true` only. */
  readonly isMlKitAvailable: boolean;
  /** ML Kit Text Recognition v2 (Latin) on the same decode path. */
  recognizeMlKit(uri: string, maxImageSide: number): Promise<OcrResult>;

  /**
   * A camera-like buffer to test `recognizeFrame` and `OcrFrameMeter` without a camera: decodes the
   * photo upright, downscales it to `maxSide` and stores it the way a camera would, YUV 4:2:0,
   * rotated so that `orientation` turns it upright again. Returns a `CVPixelBufferRef` (iOS) or an
   * `AHardwareBuffer*` (Android), as `frame.getNativeBuffer().pointer`; free it with `releaseTestFrame`.
   */
  createTestFrame(
    uri: string,
    maxSide: number,
    orientation: FrameOrientation,
  ): UInt64;
  getTestFrameInfo(pointer: UInt64): TestFrameInfo;
  releaseTestFrame(pointer: UInt64): void;
}
