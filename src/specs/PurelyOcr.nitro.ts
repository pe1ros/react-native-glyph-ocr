import type { HybridObject } from 'react-native-nitro-modules';

/** Engine that produced an {@linkcode OcrResult}. */
export type OcrEngine = 'paddle' | 'mlkit' | 'vision';

/**
 * Where the PaddleOCR models come from. Each entry is either a file name inside
 * the module's `assets/ocr/` folder or an absolute path on the device.
 */
export interface PaddleModelConfig {
  detModel: string;
  recModel: string;
  /** Recognizer dictionary, one character per line. */
  recDict: string;
  /** ONNX Runtime intra-op threads, 0 = ONNX Runtime default. */
  threads: number;
  /** Run the models with the XNNPACK execution provider instead of the default CPU one. */
  useXnnpack: boolean;
  /**
   * Pin PaddleOCR to these CPU cores (0-based), one thread per core; `threads` is ignored then.
   * Empty = no pinning. Used to estimate a budget phone on the little cores of a faster one.
   */
  cpus: number[];
}

export interface PaddleOptions {
  /** The detector input is downscaled so that its longer side is at most this many px. */
  detLimitSide: number;
  /** The photo is decoded so that its longer side is at most this many px. */
  maxImageSide: number;
  /** Probability threshold of the DB text map. */
  detThresh: number;
  /** Lines whose mean probability is lower are dropped. */
  boxThresh: number;
  /** How much a detected line is grown back (DB unclip ratio). */
  unclipRatio: number;
  /** Lines whose mean character confidence is lower are dropped. */
  dropScore: number;
}

/** Apple Vision (`VNRecognizeTextRequest`, revision 3, accurate level). */
export interface VisionOptions {
  /** The photo is decoded so that its longer side is at most this many px. */
  maxImageSide: number;
  /** `usesLanguageCorrection` of the request. */
  usesLanguageCorrection: boolean;
  /** Recognition languages in priority order, e.g. `['ru-RU', 'en-US']`. */
  recognitionLanguages: string[];
}

export interface OcrLine {
  text: string;
  /** Mean character confidence (PaddleOCR) or line confidence (ML Kit, Vision), 0..1. */
  score: number;
  /** Axis-aligned bounds in the decoded image, px. */
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface OcrResult {
  engine: OcrEngine;
  /** Recognized lines joined in reading order, one visual line per row. */
  text: string;
  lines: OcrLine[];
  /** Size of the decoded image (after EXIF rotation and downscaling). */
  imageWidth: number;
  imageHeight: number;
  /** Reading the file into a bitmap. */
  decodeMs: number;
  /** PaddleOCR only: detector preprocessing + inference + post-processing. */
  detMs: number;
  /** PaddleOCR only: cropping and recognizing all lines. */
  recMs: number;
  /** Recognition time without decoding: det + rec for PaddleOCR, the whole call for ML Kit and Vision. */
  totalMs: number;
  /** PaddleOCR only: detector input size. */
  detInputWidth: number;
  detInputHeight: number;
  /** PaddleOCR only: lines found by the detector before the confidence filter. */
  boxCount: number;
}

export interface ModelLoadInfo {
  loadMs: number;
  detBytes: number;
  recBytes: number;
  dictSize: number;
}

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

/**
 * On-device text recognition for the OCR spike. On Android: PaddleOCR (PP-OCRv5 ONNX on ONNX
 * Runtime) and ML Kit Text Recognition v2 (Latin) on the same decoded photo. On iOS: Apple Vision.
 * The other platform's methods throw.
 */
export interface PurelyOcr
  extends HybridObject<{ android: 'kotlin'; ios: 'swift' }> {
  /** Android only. */
  loadPaddle(config: PaddleModelConfig): Promise<ModelLoadInfo>;
  /** Always false on iOS. */
  readonly isPaddleLoaded: boolean;
  /** Android only. `imageUri`: a file path, `file://` or `content://` URI. */
  recognizePaddle(imageUri: string, options: PaddleOptions): Promise<OcrResult>;
  /** Android only. */
  recognizeMlKit(imageUri: string, maxImageSide: number): Promise<OcrResult>;
  /** iOS only. `imageUri`: a file path or `file://` URI. */
  recognizeVision(imageUri: string, options: VisionOptions): Promise<OcrResult>;

  /** Folder for the batch benchmark: `<app external files>/ocr-bench` on Android, `<Documents>/ocr-bench` on iOS. */
  readonly benchDir: string;
  /** Absolute paths of the JPEG/PNG/HEIC/WebP files in `dir`, sorted by name. */
  listImages(dir: string): string[];
  writeText(path: string, content: string): void;
  getDeviceSummary(): DeviceSummary;
}
