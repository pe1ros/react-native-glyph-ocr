import type { HybridObject, UInt64 } from 'react-native-nitro-modules';

// ─── Engines and languages ────────────────────────────────────────────────

/**
 * Recognition engine. `'mlkit'` is produced only by the dev entry point
 * (`react-native-glyph-ocr/dev`) and only in Android builds with ML Kit enabled.
 */
export type OcrEngine = 'vision' | 'paddle' | 'mlkit';

/** Whether a language can be recognized right now. */
export type LanguageStatus = 'ready' | 'needs-download' | 'unavailable';

export interface SupportedLanguage {
  /** BCP-47 without region where the region does not matter: `ru`, `en`, `zh-Hans`. */
  language: string;
  engine: OcrEngine;
  /** Paddle: the model pack that covers the language (`eslav`, `cyrillic`, `latin`…). */
  packId?: string;
  status: LanguageStatus;
  /** Bytes still to download before `status` becomes `ready`; 0 for Vision. */
  downloadBytes: number;
}

/** How a list of BCP-47 tags maps onto one engine. */
export interface LanguageResolution {
  engine: OcrEngine;
  /** Normalized tags in the caller's priority order: `['ru', 'en']`. */
  languages: string[];
  /** Vision: `recognitionLanguages` of the request, e.g. `['ru-RU', 'en-US']`. Empty for Paddle. */
  engineLanguages: string[];
  /** Paddle: the one recognizer pack covering all `languages`. */
  packId?: string;
  /** Tags no engine pack covers. Non-empty means creating a recognizer throws `language-not-supported`. */
  unsupported: string[];
}

// ─── Geometry ─────────────────────────────────────────────────────────────

/** A rectangle. Normalized (0..1) or pixels, as the field says; origin at the top left. */
export interface OcrRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface OcrPoint {
  x: number;
  y: number;
}

/** Size of the image the coordinates refer to: the full source image turned upright. */
export interface OcrImageSize {
  width: number;
  height: number;
}

export type RegionUnit = 'normalized' | 'pixel';

/** How a view shows the image: React Native's `resizeMode` / VisionCamera's preview `resizeMode`. */
export type ViewResizeMode = 'cover' | 'contain';

/** A view the image is shown in, when the region was drawn on screen. */
export interface RegionView {
  width: number;
  height: number;
  resizeMode: ViewResizeMode;
}

/**
 * A region of the upright source image; with `view`, a region of that view, mapped onto the
 * image by native code once it knows the image size.
 */
export interface OcrRegion {
  x: number;
  y: number;
  width: number;
  height: number;
  /** `normalized`: 0..1 of the image (or of `view`); `pixel`: image pixels (or view points). */
  unit: RegionUnit;
  view?: RegionView;
}

// ─── Result: Block → Line → Element, as in ML Kit ─────────────────────────

/** A word (or a run of characters without spaces). */
export interface OcrElement {
  text: string;
  /** 0..1. Vision has no per-word confidence: the line's is repeated. */
  confidence: number;
  /** Normalized to `OcrResult.image`, origin at the top left. */
  boundingBox: OcrRect;
  /** The same box in pixels of `OcrResult.image`. */
  pixelBoundingBox: OcrRect;
  /** Four normalized points clockwise from the text's top left: TL, TR, BR, BL. */
  cornerPoints: OcrPoint[];
  /** Degrees of the text baseline against the horizontal, clockwise positive, (-180, 180]. */
  angle: number;
}

/** One text line along one baseline, as the engine returns it. */
export interface OcrLine {
  text: string;
  confidence: number;
  boundingBox: OcrRect;
  pixelBoundingBox: OcrRect;
  cornerPoints: OcrPoint[];
  angle: number;
  /** Empty when `RecognizeOptions.output` is not `'elements'`. */
  elements: OcrElement[];
}

/** Lines grouped into a paragraph or column by the module (engines return lines only). */
export interface OcrBlock {
  text: string;
  /** Mean of the lines' confidences, weighted by their length. */
  confidence: number;
  boundingBox: OcrRect;
  pixelBoundingBox: OcrRect;
  cornerPoints: OcrPoint[];
  /** Median angle of the lines. */
  angle: number;
  lines: OcrLine[];
}

export interface OcrTimings {
  /** Reading the source into pixels: file decode, EXIF rotation, ROI crop, downscale. */
  decodeMs: number;
  /** The engine itself. */
  recognizeMs: number;
  /** decode + recognize + building the result. */
  totalMs: number;
}

/** Engine internals, filled only with `RecognizeOptions.diagnostics: true`. May change between versions. */
export interface OcrDiagnostics {
  /** `vision-rev3`, `onnxruntime-1.30.0`, `executorch-…`. */
  runtime: string;
  /** Image fed to the engine: after the ROI crop and `maxImageSide`. */
  inputWidth: number;
  inputHeight: number;
  /** Paddle: detector and line recognizer time; 0 for Vision. */
  detectorMs: number;
  recognizerMs: number;
  detectorInputWidth: number;
  detectorInputHeight: number;
  /** Paddle: lines found by the detector before `minConfidence`. Vision: lines it returned. */
  candidateLines: number;
}

export interface OcrResult {
  /**
   * `readingOrder: 'blocks'`: blocks in reading order joined with `\n`, lines inside a block
   * joined with `\n`. `'rows'`: visual rows top to bottom, pieces of a row joined with spaces.
   */
  text: string;
  /** Empty when `RecognizeOptions.output` is `'text'`. */
  blocks: OcrBlock[];
  /** The image all coordinates refer to: the full upright source, not the ROI and not the downscaled copy. */
  image: OcrImageSize;
  engine: OcrEngine;
  /** Resolved languages, BCP-47. */
  languages: string[];
  timings: OcrTimings;
  diagnostics?: OcrDiagnostics;
}

// ─── Options ──────────────────────────────────────────────────────────────

export type RecognitionLevel = 'accurate' | 'fast';

/** `auto` = EXIF for files; the others are how the pixel data is rotated relative to upright. */
export type ImageOrientation = 'auto' | 'up' | 'right' | 'down' | 'left';

/** Same strings as VisionCamera's `Frame.orientation`, declared here to avoid a native dependency. */
export type FrameOrientation = 'up' | 'right' | 'down' | 'left';

/** `blocks`: paragraphs and columns kept together. `rows`: visual rows across the whole image, top to bottom. */
export type ReadingOrder = 'blocks' | 'rows';

/** How much of the tree to build: `text` skips geometry, `lines` skips words. */
export type OcrOutput = 'text' | 'lines' | 'elements';

/** Advanced Paddle knobs. Defaults are the measured best on Pixel 6a. May change between versions. */
export interface PaddleTuning {
  /** Detector input, longer side, px. Default 960 (736 with `recognitionLevel: 'fast'`). */
  detectorSide?: number;
  /** DB probability threshold. Default 0.3 (PP-OCRv6 packs: 0.2). */
  detectorThreshold?: number;
  /** Mean probability a detected line must reach. Default 0.6 (PP-OCRv6 packs: 0.4). */
  boxThreshold?: number;
  /** How much a detected line is grown back. Default 1.5 (PP-OCRv6 packs: 1.4). */
  unclipRatio?: number;
}

export interface RecognizeOptions {
  /** Vision: `.accurate` / `.fast`. Paddle: `fast` = detector input 736 instead of 960. Default `accurate`. */
  recognitionLevel?: RecognitionLevel;
  /** Vision only; ignored by Paddle. Default true, as in Vision. `customWords` are set in `createOcr`. */
  usesLanguageCorrection?: boolean;
  /** Cropped before recognition; coordinates in the result are still in the full image. */
  roi?: OcrRegion;
  /** Default `auto`. */
  orientation?: ImageOrientation;
  /**
   * Lines below are dropped; the words of a kept line all stay. Default: Paddle 0.5,
   * Vision 0 (Vision drops weak lines itself).
   */
  minConfidence?: number;
  /** Longer side of the image fed to the engine, px, applied after the ROI crop. Default 2000; 0 = no limit. */
  maxImageSide?: number;
  /** Default `blocks`. */
  readingOrder?: ReadingOrder;
  /** Default `elements`. */
  output?: OcrOutput;
  /** Fill `OcrResult.diagnostics`. Default false. */
  diagnostics?: boolean;
  /**
   * Paddle: find out whether the text is upside down (a vote of all lines with the pack's
   * orientation classifier, about 1 ms per line) and read it turned. Boxes stay on the image as
   * given; blocks and rows follow the text. Default true; no effect when the pack has no
   * classifier, or on Vision, which reads rotated text itself.
   */
  textlineOrientation?: boolean;
  paddle?: PaddleTuning;
}

/** Options of `recognizeFrame`: no EXIF, the orientation is a parameter. */
export interface FrameRecognizeOptions {
  /** Normalized to the upright frame. */
  roi?: OcrRect;
  /** VisionCamera's `Frame.isMirrored`. */
  mirrored?: boolean;
  recognitionLevel?: RecognitionLevel;
  usesLanguageCorrection?: boolean;
  minConfidence?: number;
  /** Paddle only: Vision reads the camera buffer as it is. */
  maxImageSide?: number;
  readingOrder?: ReadingOrder;
  output?: OcrOutput;
  diagnostics?: boolean;
  /**
   * Paddle: find out whether the text is upside down (a vote of all lines with the pack's
   * orientation classifier, about 1 ms per line) and read it turned. Boxes stay on the image as
   * given; blocks and rows follow the text. Default true; no effect when the pack has no
   * classifier, or on Vision, which reads rotated text itself.
   */
  textlineOrientation?: boolean;
  paddle?: PaddleTuning;
}

/** Layout of raw pixels passed to `recognizePixels` (what react-native-nitro-image returns). */
export type RawPixelFormat = 'rgba' | 'bgra' | 'argb' | 'abgr' | 'rgb' | 'bgr';

// ─── Models ───────────────────────────────────────────────────────────────

export type ModelFormat = 'onnx' | 'ort' | 'pte' | 'dict';
/** `orientation`: the optional text line classifier that finds upside-down lines (Paddle). */
export type ModelRole =
  'detector' | 'recognizer' | 'dictionary' | 'orientation';

export interface ModelFile {
  /** Stable id, e.g. `pp-ocrv5-det-mobile`. */
  id: string;
  role: ModelRole;
  format: ModelFormat;
  /** Path under any mirror: downloaded from `<baseUrl>/<path>`, embedded as `ocr-models/<path>`. */
  path: string;
  /** Original location, used when no `baseUrl` is configured (pinned Hugging Face revision). */
  url?: string;
  /** Lower-case hex. Files are stored and looked up by it. */
  sha256: string;
  bytes: number;
  /** SPDX id, e.g. `Apache-2.0`. */
  license?: string;
}

export interface ModelPack {
  /** `eslav`, `cyrillic`, `latin`, `en`… */
  id: string;
  engine: OcrEngine;
  /** `PP-OCRv5`, `PP-OCRv6`. */
  family: string;
  /** BCP-47 tags the pack reads. */
  languages: string[];
  /** Ids from `ModelManifest.files`. Several formats may be listed; a build uses the one its runtime reads. */
  files: string[];
}

export interface ModelManifest {
  /** 1. */
  schemaVersion: number;
  /** Used for files without `url`. */
  baseUrl?: string;
  files: ModelFile[];
  /** In priority order: the first pack covering all requested languages wins. */
  packs: ModelPack[];
}

/** Where model files come from. */
export type ModelSource = 'remote' | 'embedded' | 'embedded-or-remote';

export interface ModelStoreConfig {
  /** Replaces the built-in manifest. */
  manifest?: ModelManifest;
  /** Download every file from `<baseUrl>/<file.path>` instead of `file.url`, e.g. your own server. */
  baseUrl?: string;
  /** Sent with every download request. */
  headers?: Record<string, string>;
  /** Default `embedded-or-remote`. */
  source?: ModelSource;
  /** Default: Application Support (iOS) / `noBackupFilesDir` (Android) + `/ocr-models`. */
  directory?: string;
}

export type ModelPackStatus =
  'installed' | 'embedded' | 'missing' | 'downloading' | 'corrupt';

export type PreparePhase =
  'downloading' | 'verifying' | 'loading' | 'warming-up';

export interface PrepareProgress {
  phase: PreparePhase;
  receivedBytes: number;
  totalBytes: number;
  /** 0..1 over the whole call, all phases. */
  fraction: number;
  /** File being processed. */
  fileId: string;
}

export interface DownloadResult {
  /** 0 when everything was already installed or embedded. */
  downloadedBytes: number;
  packIds: string[];
}

export interface LoadResult {
  downloadedBytes: number;
  loadMs: number;
  /** 0 without warm-up. */
  warmUpMs: number;
}

// ─── Hybrid objects ───────────────────────────────────────────────────────

/** Downloads, verifies and stores model files. One per app. */
export interface OcrModelStore extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  configure(config: ModelStoreConfig): void;
  readonly manifest: ModelManifest;
  readonly directory: string;
  getPackStatus(packId: string): ModelPackStatus;
  /** Downloads what is missing, checks sha256, moves files in atomically. Resumes `.part` files. */
  download(
    packIds: string[],
    onProgress: (progress: PrepareProgress) => void,
    requestId: number,
  ): Promise<DownloadResult>;
  /** Deletes the packs' files unless another installed pack uses them. */
  remove(packIds: string[]): Promise<void>;
  /** Deletes files no pack of the current manifest references. Returns freed bytes. */
  prune(): Promise<number>;
  cancel(requestId: number): void;
}

/**
 * One engine with one language set. Holds the loaded models (Paddle) or the request
 * settings (Vision). Requests on one recognizer run one at a time, in call order.
 */
export interface OcrRecognizer extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  readonly engine: OcrEngine;
  readonly languages: string[];
  /** Paddle: the pack in use. */
  readonly packId?: string;
  /** Models are on disk (or nothing is needed). */
  readonly isReady: boolean;
  /** Models are loaded into memory. */
  readonly isLoaded: boolean;

  /** Download what is missing, load, and optionally run one tiny recognition to warm the engine up. */
  load(
    warmUp: boolean,
    onProgress: (progress: PrepareProgress) => void,
    requestId: number,
  ): Promise<LoadResult>;

  /** Path, `file://`, `content://` (Android), `ph://` (iOS). */
  recognizeUri(
    uri: string,
    options: RecognizeOptions,
    requestId: number,
  ): Promise<OcrResult>;
  /** An encoded image (JPEG/PNG/HEIC/WebP) as base64 without the `data:` prefix. */
  recognizeBase64(
    base64: string,
    options: RecognizeOptions,
    requestId: number,
  ): Promise<OcrResult>;
  /** Raw pixels, e.g. from react-native-nitro-image `Image.toRawPixelDataAsync()`. Copied before the promise returns. */
  recognizePixels(
    pixels: ArrayBuffer,
    width: number,
    height: number,
    bytesPerRow: number,
    format: RawPixelFormat,
    options: RecognizeOptions,
    requestId: number,
  ): Promise<OcrResult>;

  /**
   * Synchronous, for a VisionCamera worklet: blocks the calling thread until done, so call it
   * from `AsyncRunner.runAsync`, not from `onFrame` itself.
   * @param nativeBufferPointer `frame.getNativeBuffer().pointer`: a `CVPixelBufferRef` on iOS,
   * an `AHardwareBuffer*` on Android (API 29+). Only read during the call; the caller releases it.
   * @param orientation `frame.orientation`.
   */
  recognizeFrame(
    nativeBufferPointer: UInt64,
    orientation: FrameOrientation,
    options?: FrameRecognizeOptions,
  ): OcrResult;

  /** Cancels a queued or running request; it rejects with `cancelled`. */
  cancel(requestId: number): void;
}

/** Cheap per-frame focus, motion and light measurements for the scanner. */
export interface FrameQuality {
  /** Variance of the Laplacian of luma in the ROI, on a ~256 px copy. Higher is sharper. */
  sharpness: number;
  /** Mean absolute luma change against the previous measured frame, 0..1. 1 on the first frame. */
  motion: number;
  /** Mean luma, 0..1. */
  brightness: number;
}

export interface OcrFrameMeter extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  /** Synchronous, about 1 ms; safe to call in `onFrame` on every frame. */
  measure(
    nativeBufferPointer: UInt64,
    orientation: FrameOrientation,
    roi?: OcrRect,
  ): FrameQuality;
  /** Forget the previous frame (e.g. after the camera moved to a new product). */
  reset(): void;
}

/** Entry object, autolinked. */
export interface GlyphOcrFactory extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  /** `vision` on iOS, `paddle` on Android. */
  readonly defaultEngine: OcrEngine;
  /** Engines `createRecognizer` accepts in this build: `['vision']` on iOS, `['paddle']` on Android. ML Kit is in `/dev` only. */
  readonly availableEngines: OcrEngine[];
  readonly models: OcrModelStore;
  getSupportedLanguages(engine?: OcrEngine): SupportedLanguage[];
  resolveLanguages(
    engine: OcrEngine,
    languages: string[],
    packId?: string,
  ): LanguageResolution;
  /**
   * Cheap: nothing is loaded until `load()` or the first recognition.
   * @param customWords Vision's `customWords` (with language correction on); ignored by Paddle.
   * Per recognizer, not per call: an optional `string[]` in a struct does not compile in Swift
   * (std::optional<std::vector<std::string>> breaks the std::vector conformances, Xcode 26.1).
   */
  createRecognizer(
    engine: OcrEngine,
    languages: string[],
    customWords: string[],
    packId?: string,
    threads?: number,
  ): OcrRecognizer;
  createFrameMeter(): OcrFrameMeter;
}
