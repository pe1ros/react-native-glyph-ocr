import { OcrError } from './errors';
import type {
  OcrRecognizer,
  OcrResult,
  RawPixelFormat,
  RecognizeOptions,
} from './specs/Ocr.nitro';

/**
 * The part of react-native-nitro-image's `Image` the module uses. Typed structurally,
 * so react-native-nitro-image stays an optional peer with no native link.
 */
export interface NitroImageLike {
  readonly width: number;
  readonly height: number;
  toRawPixelDataAsync(allowGpu?: boolean): Promise<{
    buffer: ArrayBuffer;
    width: number;
    height: number;
    pixelFormat: string;
  }>;
}

/**
 * - `'/abs/path.jpg'`, `'file://…'`, `'content://…'` (Android), `'ph://<localIdentifier>'` (iOS);
 * - `'data:image/jpeg;base64,…'` or `{ base64 }` without the prefix;
 * - `{ uri }`, as in React Native's `ImageURISource`;
 * - an `Image` from react-native-nitro-image.
 */
export type OcrSource =
  | string
  | { uri: string }
  | { base64: string }
  | NitroImageLike;

const PIXEL_FORMATS: Record<string, RawPixelFormat> = {
  RGBA: 'rgba',
  RGBX: 'rgba',
  BGRA: 'bgra',
  BGRX: 'bgra',
  ARGB: 'argb',
  XRGB: 'argb',
  ABGR: 'abgr',
  XBGR: 'abgr',
  RGB: 'rgb',
  BGR: 'bgr',
};

function isNitroImage(source: object): source is NitroImageLike {
  return (
    'toRawPixelDataAsync' in source &&
    typeof (source as NitroImageLike).toRawPixelDataAsync === 'function'
  );
}

export async function recognizeSource(
  recognizer: OcrRecognizer,
  source: OcrSource,
  options: RecognizeOptions,
  requestId: number,
): Promise<OcrResult> {
  if (typeof source === 'string') {
    return recognizeString(recognizer, source, options, requestId);
  }
  if (isNitroImage(source)) {
    const raw = await source.toRawPixelDataAsync(false);
    const format = PIXEL_FORMATS[raw.pixelFormat.toUpperCase()];
    if (format == null) {
      throw new OcrError(
        'unsupported-source',
        `Unsupported pixel format ${raw.pixelFormat}`,
      );
    }
    return recognizer.recognizePixels(
      raw.buffer,
      raw.width,
      raw.height,
      raw.buffer.byteLength / raw.height,
      format,
      options,
      requestId,
    );
  }
  if ('base64' in source) {
    return recognizer.recognizeBase64(source.base64, options, requestId);
  }
  if ('uri' in source) {
    return recognizeString(recognizer, source.uri, options, requestId);
  }
  throw new OcrError('unsupported-source', 'Unknown source');
}

function recognizeString(
  recognizer: OcrRecognizer,
  source: string,
  options: RecognizeOptions,
  requestId: number,
): Promise<OcrResult> {
  if (source.startsWith('data:')) {
    const i = source.indexOf(';base64,');
    if (i < 0) {
      throw new OcrError(
        'unsupported-source',
        'Only base64 data URIs are supported',
      );
    }
    return recognizer.recognizeBase64(source.slice(i + 8), options, requestId);
  }
  if (/^https?:\/\//i.test(source)) {
    // On purpose: the module never touches the network with images.
    throw new OcrError(
      'unsupported-source',
      'Download the image to a file first',
    );
  }
  return recognizer.recognizeUri(source, options, requestId);
}
