export type OcrErrorCode =
  /** The source kind or URI scheme is not supported on this platform (`ph://` on Android, `http://`). */
  | 'unsupported-source'
  /** The file, content URI or Photos asset does not exist or cannot be opened. */
  | 'source-not-found'
  /** No permission to read the source (Photos access, revoked content URI). */
  | 'source-permission-denied'
  /** Not an image, or a corrupt one. */
  | 'decode-failed'
  /** Bad options: ROI outside the image, empty language list, `zh` without a script… */
  | 'invalid-argument'
  /** No engine pack covers a language, or `fast` was asked for a language Vision reads only in `accurate`. */
  | 'language-not-supported'
  /** The engine is not compiled in (Paddle on iOS, ML Kit outside dev builds) or the OS is too old. */
  | 'engine-unavailable'
  /** Models are not on disk and the source is `embedded` only. */
  | 'models-not-ready'
  | 'download-failed'
  | 'checksum-mismatch'
  | 'insufficient-storage'
  /** The model file is there but the runtime cannot load it (corrupt, wrong format for this build). */
  | 'model-load-failed'
  /** Null pointer, unsupported pixel format (`private` on Android), Android below 10. */
  | 'frame-unsupported'
  | 'cancelled'
  | 'out-of-memory'
  /** The recognizer was disposed. */
  | 'disposed'
  | 'internal';

const CODES = new Set<string>([
  'unsupported-source',
  'source-not-found',
  'source-permission-denied',
  'decode-failed',
  'invalid-argument',
  'language-not-supported',
  'engine-unavailable',
  'models-not-ready',
  'download-failed',
  'checksum-mismatch',
  'insufficient-storage',
  'model-load-failed',
  'frame-unsupported',
  'cancelled',
  'out-of-memory',
  'disposed',
  'internal',
]);

export class OcrError extends Error {
  override readonly name = 'OcrError';

  constructor(
    readonly code: OcrErrorCode,
    message: string,
    /** Extra fields from native code: `{ language: 'kk' }`, `{ status: 404, url }`. */
    readonly details?: Readonly<Record<string, unknown>>,
    readonly cause?: unknown,
  ) {
    super(message);
  }
}

/**
 * Native code throws `[ocr:<code>] <message>` optionally followed by ` {json details}`, on one line.
 * Nitro turns that into a plain `Error`; this restores the typed error.
 */
export function toOcrError(e: unknown): OcrError {
  if (e instanceof OcrError) {
    return e;
  }
  const raw = e instanceof Error ? e.message : String(e);
  // One line: Nitro appends the native stack trace (`\n\tat com.…`) after it on Android.
  const m = /\[ocr:([a-z-]+)\]\s*([^{\n]*)(\{[^\n]*\})?/.exec(raw);
  const code = m?.[1];
  if (m == null || code == null || !CODES.has(code)) {
    return new OcrError('internal', raw, undefined, e);
  }
  let details: Record<string, unknown> | undefined;
  try {
    details = m[3] ? (JSON.parse(m[3]) as Record<string, unknown>) : undefined;
  } catch {
    details = undefined;
  }
  return new OcrError(code as OcrErrorCode, (m[2] ?? '').trim(), details, e);
}
