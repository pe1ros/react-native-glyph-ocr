import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  type CameraFrameOutput,
  type CameraPhotoOutput,
  CommonResolutions,
  type Frame,
  type Size,
  useAsyncRunner,
  useFrameOutput,
} from 'react-native-vision-camera';
import { createSynchronizable, scheduleOnRN } from 'react-native-worklets';

import { OcrError, toOcrError } from '../errors';
import { getFactory, type Ocr } from '../ocr';
import type {
  FrameQuality,
  FrameRecognizeOptions,
  OcrFrameMeter,
  OcrRect,
  OcrResult,
  ViewResizeMode,
} from '../specs/Ocr.nitro';

/**
 * Focus, motion and light of camera frames, for a scanner of your own (`useTextScanner` makes one).
 * `measure(frame.getNativeBuffer().pointer, frame.orientation, roi)` takes about 1 ms.
 */
export function createFrameMeter(): OcrFrameMeter {
  return getFactory().createFrameMeter();
}

// ─── Geometry ─────────────────────────────────────────────────────────────

export interface ViewSize {
  width: number;
  height: number;
}

function clamp01(v: number) {
  'worklet';
  return Math.min(1, Math.max(0, v));
}

/** A rect normalized to a view → the same area normalized to the upright image the view shows. */
export function viewRectToImageRect(
  rect: OcrRect,
  view: ViewSize,
  image: ViewSize,
  resizeMode: ViewResizeMode = 'cover',
): OcrRect {
  'worklet';
  const pick = resizeMode === 'cover' ? Math.max : Math.min;
  const scale = pick(view.width / image.width, view.height / image.height);
  const shownW = image.width * scale;
  const shownH = image.height * scale;
  const offX = (view.width - shownW) / 2;
  const offY = (view.height - shownH) / 2;
  const x0 = clamp01((rect.x * view.width - offX) / shownW);
  const y0 = clamp01((rect.y * view.height - offY) / shownH);
  const x1 = clamp01(((rect.x + rect.width) * view.width - offX) / shownW);
  const y1 = clamp01(((rect.y + rect.height) * view.height - offY) / shownH);
  return { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
}

/** The inverse: a box from `OcrResult` (normalized to the image) → normalized to the view, for overlays. */
export function imageRectToViewRect(
  rect: OcrRect,
  view: ViewSize,
  image: ViewSize,
  resizeMode: ViewResizeMode = 'cover',
): OcrRect {
  'worklet';
  const pick = resizeMode === 'cover' ? Math.max : Math.min;
  const scale = pick(view.width / image.width, view.height / image.height);
  const offX = (view.width - image.width * scale) / 2;
  const offY = (view.height - image.height * scale) / 2;
  return {
    x: (rect.x * image.width * scale + offX) / view.width,
    y: (rect.y * image.height * scale + offY) / view.height,
    width: (rect.width * image.width * scale) / view.width,
    height: (rect.height * image.height * scale) / view.height,
  };
}

// ─── useTextScanner ───────────────────────────────────────────────────────

/** Where to look for text. Without `view`, `rect` is normalized to the upright frame. */
export interface ScanRegion {
  rect: OcrRect;
  /** The preview's size on screen (from `onLayout`): `rect` is normalized to it. */
  view?: ViewSize;
  /** The preview's resize mode. Default `cover`. */
  resizeMode?: ViewResizeMode;
}

export type ScannerState =
  | 'idle' // no Ocr yet, or not active
  | 'searching' // waiting for a sharp, still, bright enough frame
  | 'too-dark'
  | 'hold-still'
  | 'recognizing'
  | 'done'
  | 'error';

export interface UseTextScannerOptions {
  /** From `useOcr()` or `createOcr()`. The scanner waits while it is undefined or not loaded. */
  ocr: Ocr | undefined;
  region?: ScanRegion;
  /** Default true. */
  isActive?: boolean;
  /**
   * Thresholds of `FrameQuality`, first estimates from the 61 bench photos as 1920 px frames
   * (blurred, darkened and shifted copies): calibrate them on recorded camera frames.
   * Sharpness depends on the label as much as on focus (206–12 465 on sharp photos), so a frame
   * must also reach `relativeSharpness` of the sharpest frame of the last `peakWindowMs`.
   * Default 50: below it even a busy label is badly out of focus.
   */
  minSharpness?: number;
  /** Default 0.5: a Gaussian blur of σ = 3 px leaves at most 0.49 of the sharpness, σ = 2 a median 0.43. */
  relativeSharpness?: number;
  /** Default 1500 ms. */
  peakWindowMs?: number;
  /** Default 0.05: a 2 px shift of a 1920 px frame measures 0.03 (median), 5 px 0.06. */
  maxMotion?: number;
  /** Default 0.15: the darkest bench label measures 0.21; the same photos at 30% exposure 0.13. */
  minBrightness?: number;
  /** How long the frame must stay good before recognizing. Default 400 ms. */
  stableMs?: number;
  /** After a rejected result, wait this long before trying again. Default 600 ms. */
  retryDelayMs?: number;
  recognizeOptions?: Omit<FrameRecognizeOptions, 'roi' | 'mirrored'>;
  /**
   * Take a photo instead of using the video frame once the frame is good: slower but
   * the quality of a full photo. The output must be in the Camera's `outputs`.
   */
  photoOutput?: CameraPhotoOutput;
  /** Frame output resolution. Default `CommonResolutions.UHD_4_3`. */
  targetResolution?: Size;
  /** JS thread. Return false to keep scanning, e.g. when a keyword you expect is missing. */
  accept?: (result: OcrResult) => boolean;
  onResult?: (result: OcrResult) => void;
  onError?: (error: OcrError) => void;
}

export interface UseTextScannerResult {
  /** Put it in `<Camera outputs={[frameOutput, …]} />`. */
  frameOutput: CameraFrameOutput;
  state: ScannerState;
  /** Last measurement, about 4 times a second. */
  quality: FrameQuality | undefined;
  result: OcrResult | undefined;
  error: OcrError | undefined;
  /** Scan again after `done` or `error`. */
  reset: () => void;
}

const SEARCHING = 0;
const RECOGNIZING = 1;
const DONE = 2;

interface ScanState {
  phase: number;
  stableSince: number;
  retryAt: number;
  reportedAt: number;
  /** Sharpest frame of the current window, and when it was seen. */
  peak: number;
  peakAt: number;
}

/**
 * What the async runner hands back. Functions captured by the nested `runAsync` worklet arrive
 * there as plain objects (react-native-worklets 0.9.1 + VisionCamera 5.0.11: "Object is not a
 * function"), so the runner cannot `scheduleOnRN` itself: `onFrame` forwards this on the next frame.
 */
interface Outcome {
  result?: OcrResult;
  error?: string;
}

const INITIAL_SCAN: ScanState = {
  phase: SEARCHING,
  stableSince: 0,
  retryAt: 0,
  reportedAt: 0,
  peak: 0,
  peakAt: 0,
};

export function useTextScanner(
  options: UseTextScannerOptions,
): UseTextScannerResult {
  const {
    ocr,
    region,
    isActive = true,
    minSharpness = 50,
    relativeSharpness = 0.5,
    peakWindowMs = 1500,
    maxMotion = 0.05,
    minBrightness = 0.15,
    stableMs = 400,
    retryDelayMs = 600,
    recognizeOptions,
    photoOutput,
    targetResolution = CommonResolutions.UHD_4_3,
  } = options;

  const [state, setState] = useState<ScannerState>('idle');
  const [quality, setQuality] = useState<FrameQuality>();
  const [result, setResult] = useState<OcrResult>();
  const [error, setError] = useState<OcrError>();
  const callbacks = useRef(options);
  callbacks.current = options;

  const meter = useMemo(() => createFrameMeter(), []);
  useEffect(() => () => meter.dispose(), [meter]);
  const asyncRunner = useAsyncRunner();
  const scan = useMemo(
    () => createSynchronizable<ScanState>({ ...INITIAL_SCAN }),
    [],
  );
  const outcome = useMemo(() => createSynchronizable<Outcome>({}), []);

  const ready = ocr != null && ocr.isLoaded && isActive;
  const recognizer = ready ? ocr.recognizer : undefined;

  const finish = useCallback(
    (r: OcrResult) => {
      if (callbacks.current.accept?.(r) === false) {
        scan.setBlocking(s => ({
          ...s,
          phase: SEARCHING,
          stableSince: 0,
          retryAt: Date.now() + retryDelayMs,
        }));
        setState('searching');
        return;
      }
      scan.setBlocking(s => ({ ...s, phase: DONE }));
      setResult(r);
      setState('done');
      callbacks.current.onResult?.(r);
    },
    [scan, retryDelayMs],
  );

  const fail = useCallback(
    (e: unknown) => {
      const err = toOcrError(e);
      scan.setBlocking(s => ({ ...s, phase: DONE }));
      setError(err);
      setState('error');
      callbacks.current.onError?.(err);
    },
    [scan],
  );

  const report = useCallback((q: FrameQuality, s: ScannerState) => {
    setQuality(q);
    setState(s);
  }, []);

  const capturePhoto = useCallback(async () => {
    try {
      if (ocr == null || photoOutput == null) {
        throw new OcrError('internal', 'No photo output');
      }
      const photo = await photoOutput.capturePhotoToFile(
        { enableShutterSound: false, flashMode: 'off' },
        {},
      );
      const roi = region && {
        ...region.rect,
        unit: 'normalized' as const,
        view: region.view && {
          ...region.view,
          resizeMode: region.resizeMode ?? 'cover',
        },
      };
      finish(await ocr.recognize(photo.filePath, { ...recognizeOptions, roi }));
    } catch (e) {
      fail(e);
    }
  }, [ocr, photoOutput, region, recognizeOptions, finish, fail]);

  const onFrame = useCallback(
    (frame: Frame) => {
      'worklet';
      const done = outcome.getDirty();
      if (done.result != null || done.error != null) {
        outcome.setBlocking({});
        if (done.result != null) {
          scheduleOnRN(finish, done.result);
        } else {
          scheduleOnRN(fail, done.error);
        }
      }
      const s = scan.getDirty();
      const now = Date.now();
      if (recognizer == null || s.phase !== SEARCHING || now < s.retryAt) {
        frame.dispose();
        return;
      }
      const sideways =
        frame.orientation === 'left' || frame.orientation === 'right';
      const upright = sideways
        ? { width: frame.height, height: frame.width }
        : { width: frame.width, height: frame.height };
      const roi =
        region == null
          ? undefined
          : region.view == null
            ? region.rect
            : viewRectToImageRect(
                region.rect,
                region.view,
                upright,
                region.resizeMode,
              );

      // 1. Measure every frame: ~1 ms on a small copy of the ROI's luma.
      let q: FrameQuality;
      let buffer: { pointer: bigint; release: () => void } | undefined;
      try {
        // Throws on Android when VisionCamera was built with minSdk < 26 (no HardwareBuffer access).
        buffer = frame.getNativeBuffer();
        q = meter.measure(buffer.pointer, frame.orientation, roi);
      } catch (e) {
        buffer?.release();
        frame.dispose();
        scan.setBlocking({ ...s, phase: DONE });
        const message = e instanceof Error ? e.message : String(e);
        scheduleOnRN(
          fail,
          message.includes('[ocr:')
            ? message
            : `[ocr:frame-unsupported] ${message}`,
        );
        return;
      }
      buffer.release();
      // The window's sharpest frame tells how sharp this label can look (autofocus settles on it).
      const renew = q.sharpness >= s.peak || now - s.peakAt > peakWindowMs;
      const peak = renew ? q.sharpness : s.peak;
      const peakAt = renew ? now : s.peakAt;
      const good =
        q.brightness >= minBrightness &&
        q.sharpness >= minSharpness &&
        q.sharpness >= relativeSharpness * peak &&
        q.motion <= maxMotion;
      const stableSince = good ? s.stableSince || now : 0;
      const label: ScannerState =
        q.brightness < minBrightness
          ? 'too-dark'
          : good
            ? 'searching'
            : 'hold-still';
      const reportedAt = now - s.reportedAt > 250 ? now : s.reportedAt;
      if (reportedAt === now) {
        scheduleOnRN(report, q, label);
      }

      if (!good || now - stableSince < stableMs) {
        scan.setBlocking({ ...s, stableSince, reportedAt, peak, peakAt });
        frame.dispose();
        return;
      }

      // 2. Good for `stableMs`: recognize once.
      scan.setBlocking({
        ...s,
        phase: RECOGNIZING,
        stableSince: 0,
        reportedAt,
        peak,
        peakAt,
      });
      scheduleOnRN(report, q, 'recognizing');
      if (photoOutput != null) {
        frame.dispose();
        scheduleOnRN(capturePhoto);
        return;
      }
      const handled = asyncRunner.runAsync(() => {
        'worklet';
        // A fresh native buffer: the runner's thread owns the frame until it disposes it.
        const b = frame.getNativeBuffer();
        try {
          const r = recognizer.recognizeFrame(b.pointer, frame.orientation, {
            ...recognizeOptions,
            roi,
            mirrored: frame.isMirrored,
          });
          outcome.setBlocking({ result: r });
        } catch (e) {
          outcome.setBlocking({
            error: e instanceof Error ? e.message : String(e),
          });
        } finally {
          b.release();
          frame.dispose();
        }
      });
      if (!handled) {
        scan.setBlocking({
          ...s,
          phase: SEARCHING,
          stableSince: 0,
          reportedAt,
        });
        frame.dispose();
      }
    },
    [
      recognizer,
      meter,
      scan,
      outcome,
      region,
      minBrightness,
      minSharpness,
      relativeSharpness,
      peakWindowMs,
      maxMotion,
      stableMs,
      recognizeOptions,
      photoOutput,
      asyncRunner,
      report,
      finish,
      fail,
      capturePhoto,
    ],
  );

  const frameOutput = useFrameOutput({
    // CPU-readable on both platforms; Android's `native` is often GPU-only (`private`).
    pixelFormat: 'yuv',
    targetResolution,
    dropFramesWhileBusy: true,
    onFrame,
  });

  useEffect(() => {
    setState(ready ? 'searching' : 'idle');
  }, [ready]);

  const reset = useCallback(() => {
    meter.reset();
    scan.setBlocking({ ...INITIAL_SCAN });
    outcome.setBlocking({});
    setResult(undefined);
    setError(undefined);
    setState(ready ? 'searching' : 'idle');
  }, [meter, scan, outcome, ready]);

  return { frameOutput, state, quality, result, error, reset };
}
