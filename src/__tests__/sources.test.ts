import { OcrError } from '../errors';
import { recognizeSource } from '../sources';
import type { OcrRecognizer } from '../specs/Ocr.nitro';

function fakeRecognizer() {
  const result = { text: 'ok' };
  return {
    recognizeUri: jest.fn(async () => result),
    recognizeBase64: jest.fn(async () => result),
    recognizePixels: jest.fn(async () => result),
  } as unknown as OcrRecognizer & {
    recognizeUri: jest.Mock;
    recognizeBase64: jest.Mock;
    recognizePixels: jest.Mock;
  };
}

describe('recognizeSource', () => {
  it('passes paths and file, content and ph URIs to recognizeUri', async () => {
    const r = fakeRecognizer();
    for (const uri of [
      '/data/label.jpg',
      'file:///data/label.jpg',
      'content://media/external/images/1',
      'ph://ABC/L0/001',
    ]) {
      await recognizeSource(r, uri, {}, 1);
    }
    await recognizeSource(r, { uri: 'file:///a.jpg' }, {}, 2);
    expect(r.recognizeUri.mock.calls.map(c => c[0])).toEqual([
      '/data/label.jpg',
      'file:///data/label.jpg',
      'content://media/external/images/1',
      'ph://ABC/L0/001',
      'file:///a.jpg',
    ]);
  });

  it('strips the prefix of base64 data URIs', async () => {
    const r = fakeRecognizer();
    await recognizeSource(
      r,
      'data:image/png;base64,AAAA',
      { output: 'text' },
      7,
    );
    await recognizeSource(r, { base64: 'BBBB' }, {}, 8);
    expect(r.recognizeBase64.mock.calls).toEqual([
      ['AAAA', { output: 'text' }, 7],
      ['BBBB', {}, 8],
    ]);
  });

  it('refuses http(s) URLs and non-base64 data URIs', async () => {
    const r = fakeRecognizer();
    await expect(
      recognizeSource(r, 'https://example.com/a.jpg', {}, 1),
    ).rejects.toMatchObject({ code: 'unsupported-source' });
    await expect(
      recognizeSource(r, 'HTTP://example.com/a.jpg', {}, 1),
    ).rejects.toBeInstanceOf(OcrError);
    await expect(
      recognizeSource(r, 'data:text/plain,hello', {}, 1),
    ).rejects.toMatchObject({ code: 'unsupported-source' });
    expect(r.recognizeUri).not.toHaveBeenCalled();
  });

  it('reads nitro images as raw pixels', async () => {
    const r = fakeRecognizer();
    const buffer = new ArrayBuffer(4 * 3 * 2);
    const image = {
      width: 3,
      height: 2,
      toRawPixelDataAsync: async () => ({
        buffer,
        width: 3,
        height: 2,
        pixelFormat: 'BGRA',
      }),
    };
    await recognizeSource(r, image, {}, 3);
    expect(r.recognizePixels).toHaveBeenCalledWith(
      buffer,
      3,
      2,
      12,
      'bgra',
      {},
      3,
    );
  });

  it('rejects unknown pixel formats', async () => {
    const r = fakeRecognizer();
    const image = {
      width: 1,
      height: 1,
      toRawPixelDataAsync: async () => ({
        buffer: new ArrayBuffer(2),
        width: 1,
        height: 1,
        pixelFormat: 'RGB565',
      }),
    };
    await expect(recognizeSource(r, image, {}, 1)).rejects.toMatchObject({
      code: 'unsupported-source',
    });
  });
});
