import { OcrError, toOcrError } from '../errors';

describe('toOcrError', () => {
  it('restores the code, message and details thrown by native code', () => {
    const e = toOcrError(
      new Error(
        '[ocr:language-not-supported] paddle cannot read kk {"language":"kk"}',
      ),
    );
    expect(e).toBeInstanceOf(OcrError);
    expect(e.code).toBe('language-not-supported');
    expect(e.message).toBe('paddle cannot read kk');
    expect(e.details).toEqual({ language: 'kk' });
  });

  it('finds the marker inside a longer Nitro message', () => {
    const e = toOcrError(
      new Error(
        'GlyphOcrRecognizer.recognizeUri(...): [ocr:source-not-found] No such file',
      ),
    );
    expect(e.code).toBe('source-not-found');
    expect(e.message).toBe('No such file');
    expect(e.details).toBeUndefined();
  });

  it('drops the native stack trace Nitro appends on Android', () => {
    const e = toOcrError(
      new Error(
        '[ocr:decode-failed] Not an image, or a corrupt one\n\tat com.margelo.nitro.glyphocr.ImageSource.decodeEncoded(ImageSource.kt:88)\n\tat kotlin.{x}',
      ),
    );
    expect(e.code).toBe('decode-failed');
    expect(e.message).toBe('Not an image, or a corrupt one');
    expect(e.details).toBeUndefined();
  });

  it('reads details before a stack trace', () => {
    const e = toOcrError(
      new Error(
        '[ocr:download-failed] HTTP 404 {"status":404}\n\tat com.x(Y.kt:1)',
      ),
    );
    expect(e.details).toEqual({ status: 404 });
  });

  it('keeps an OcrError as it is', () => {
    const original = new OcrError('cancelled', 'Aborted');
    expect(toOcrError(original)).toBe(original);
  });

  it('maps unknown codes and plain errors to internal', () => {
    expect(toOcrError(new Error('[ocr:no-such-code] x')).code).toBe('internal');
    const plain = toOcrError(new Error('boom'));
    expect(plain.code).toBe('internal');
    expect(plain.message).toBe('boom');
    expect(toOcrError('text').message).toBe('text');
  });

  it('survives broken JSON details', () => {
    const e = toOcrError(
      new Error('[ocr:download-failed] HTTP 500 {not json}'),
    );
    expect(e.code).toBe('download-failed');
    expect(e.details).toBeUndefined();
  });
});
