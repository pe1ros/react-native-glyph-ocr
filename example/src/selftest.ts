import { Platform } from 'react-native';
import {
  configureModels,
  createOcr,
  getModelStore,
  getSupportedLanguages,
  isReady,
  type Ocr,
  OcrError,
  type OcrLine,
  type OcrResult,
  prepare,
} from 'react-native-glyph-ocr';
import { createFrameMeter } from 'react-native-glyph-ocr/camera';
import { getOcrDevTools } from 'react-native-glyph-ocr/dev';
import { Images } from 'react-native-nitro-image';

import {
  SAMPLE_LABEL_BASE64,
  SAMPLE_LABEL_EXIF6_BASE64,
  SAMPLE_SIZE,
  SAMPLE_WORDS,
} from './sample';

const LANGUAGES = ['ru', 'en'];

/**
 * Checks the public API on a device against the bundled label: sources, EXIF, ROI, output modes,
 * camera-like frames, the frame meter, cancelling, errors and (optionally) a model download.
 * Resolves with a summary like `0 failed of 44`, also written with every line to
 * `<benchDir>/out/selftest.txt` (`getOcrDevTools().benchDir`) for scripts to read.
 */
export async function runSelfTest(
  options: { download: boolean },
  log: (line: string) => void,
): Promise<string> {
  const lines: string[] = [];
  const summary = await runChecks(options, line => {
    lines.push(line);
    log(line);
  }).catch(e => `crashed: ${String(e)}`);
  const dev = getOcrDevTools();
  dev.writeText(
    `${dev.benchDir}/out/selftest.txt`,
    [...lines, summary, ''].join('\n'),
  );
  return summary;
}

async function runChecks(
  options: { download: boolean },
  log: (line: string) => void,
): Promise<string> {
  let failed = 0;
  let total = 0;
  const check = (
    name: string,
    ok: boolean,
    info: Record<string, unknown> = {},
  ) => {
    total++;
    if (!ok) {
      failed++;
    }
    log(
      `${ok ? 'OK  ' : 'FAIL'} ${name} ${JSON.stringify(info).slice(0, 300)}`,
    );
  };
  const expectError = async (
    name: string,
    code: string,
    run: () => unknown,
  ) => {
    try {
      await run();
      check(name, false, { expected: code, got: 'no error' });
    } catch (e) {
      const got = e instanceof OcrError ? e.code : `not OcrError: ${String(e)}`;
      check(name, got === code, {
        expected: code,
        got,
        message: e instanceof Error ? e.message : String(e),
      });
    }
  };

  const ocr: Ocr = createOcr({ languages: LANGUAGES });
  const loaded = await ocr.prepare();
  check('prepare', ocr.isLoaded, {
    loaded,
    engine: ocr.engine,
    packId: ocr.packId,
  });

  // The label as a file, for the path, file:// and test-frame sources.
  const encoded = decodeBase64(SAMPLE_LABEL_BASE64);
  const sampleImage = await Images.loadFromEncodedImageDataAsync({
    buffer: encoded.buffer,
    width: SAMPLE_SIZE.width,
    height: SAMPLE_SIZE.height,
    imageFormat: 'jpg',
  });
  const upright = await sampleImage.saveToTemporaryFileAsync('jpg', 95);

  // ─── Languages ─────────────────────────────────────────────────────────
  const languages = getSupportedLanguages();
  check('getSupportedLanguages', languages.length > 0, {
    count: languages.length,
    sample: languages
      .slice(0, 6)
      .map(l => `${l.language}/${l.packId ?? '-'}/${l.status}`),
  });
  check('isReady(ru)', isReady('ru'), {});
  check('isReady(xx) is false', !isReady('xx'), {});
  await expectError('unknown language', 'language-not-supported', () =>
    createOcr({ languages: ['xx'] }),
  );
  if (Platform.OS === 'android') {
    await expectError('ru + de need two packs', 'language-not-supported', () =>
      createOcr({ languages: ['ru', 'de'] }),
    );
    await expectError('vision on Android', 'engine-unavailable', () =>
      createOcr({ languages: ['ru'], engine: 'vision' }),
    );
  } else {
    await expectError('zh without a script', 'invalid-argument', () =>
      createOcr({ languages: ['zh'] }),
    );
    // Either a plain build (no Paddle) or one made with GlyphOcr_paddleOnIos=1.
    try {
      createOcr({ languages: ['ru'], engine: 'paddle' }).dispose();
      check('paddle on iOS is built in', true);
    } catch (e) {
      check(
        'paddle on iOS is not built in',
        e instanceof OcrError && e.code === 'engine-unavailable',
        { got: e instanceof OcrError ? e.code : String(e) },
      );
    }
    await expectError(
      'fast level has no Russian',
      'language-not-supported',
      () => ocr.recognize(upright, { recognitionLevel: 'fast' }),
    );
  }

  // ─── Sources ───────────────────────────────────────────────────────────
  const base = await ocr.recognize(upright, {
    readingOrder: 'rows',
    diagnostics: true,
  });
  const missing = SAMPLE_WORDS.filter(
    w => !base.text.toLowerCase().includes(w),
  );
  check('file path: reads the label', missing.length === 0, {
    missing,
    image: base.image,
    lines: allLines(base).length,
    timings: base.timings,
    runtime: base.diagnostics?.runtime,
    text: base.text.slice(0, 80),
  });
  check(
    'result.image is the full source',
    base.image.width === SAMPLE_SIZE.width &&
      base.image.height === SAMPLE_SIZE.height,
    { image: base.image },
  );
  check(
    'boxes are normalized',
    allLines(base).every(
      l =>
        l.boundingBox.x >= 0 &&
        l.boundingBox.y >= 0 &&
        l.boundingBox.x + l.boundingBox.width <= 1.001 &&
        l.boundingBox.y + l.boundingBox.height <= 1.001 &&
        Math.abs(
          l.pixelBoundingBox.width - l.boundingBox.width * base.image.width,
        ) < 2,
    ),
  );
  const fileUri = await ocr.recognize(`file://${upright}`, {
    readingOrder: 'rows',
  });
  check('file:// uri', fileUri.text === base.text, {});
  const fromBase64 = await ocr.recognize(
    { base64: SAMPLE_LABEL_BASE64 },
    { readingOrder: 'rows' },
  );
  check('{ base64 }', similarity(fromBase64.text, base.text) > 0.95, {
    similarity: similarity(fromBase64.text, base.text),
  });
  const dataUri = await ocr.recognize(
    `data:image/jpeg;base64,${SAMPLE_LABEL_BASE64}`,
    { readingOrder: 'rows' },
  );
  check('data: uri', dataUri.text === fromBase64.text, {});
  const fromImage = await ocr.recognize(sampleImage, { readingOrder: 'rows' });
  check('nitro Image', similarity(fromImage.text, base.text) > 0.9, {
    similarity: similarity(fromImage.text, base.text),
    image: fromImage.image,
  });
  await expectError('http uri', 'unsupported-source', () =>
    ocr.recognize('https://example.com/a.jpg'),
  );
  await expectError('missing file', 'source-not-found', () =>
    ocr.recognize(`${upright}.missing.jpg`),
  );
  await expectError('not an image', 'decode-failed', () =>
    ocr.recognize({ base64: 'bm90IGFuIGltYWdl' }),
  );
  await expectError(
    Platform.OS === 'android' ? 'ph:// on Android' : 'content:// on iOS',
    'unsupported-source',
    () =>
      ocr.recognize(
        Platform.OS === 'android' ? 'ph://ABC' : 'content://media/1',
      ),
  );

  // ─── EXIF and orientation ──────────────────────────────────────────────
  const exif6 = await ocr.recognize(
    { base64: SAMPLE_LABEL_EXIF6_BASE64 },
    { readingOrder: 'rows' },
  );
  check(
    'EXIF 6 is applied',
    exif6.image.width === SAMPLE_SIZE.width &&
      similarity(exif6.text, base.text) > 0.9,
    {
      image: exif6.image,
      similarity: similarity(exif6.text, base.text),
      boxes: boxMatch(base, exif6),
    },
  );
  const exifIgnored = await ocr.recognize(
    { base64: SAMPLE_LABEL_EXIF6_BASE64 },
    { orientation: 'up', output: 'text' },
  );
  check(
    'orientation: up ignores EXIF',
    exifIgnored.image.width === SAMPLE_SIZE.height,
    { image: exifIgnored.image },
  );
  const turned = await ocr.recognize(upright, {
    orientation: 'left',
    output: 'text',
  });
  check(
    'orientation override turns the image',
    turned.image.width === base.image.height,
    { image: turned.image },
  );

  // ─── Upside down ───────────────────────────────────────────────────────
  // Pixels turned 180° (not EXIF): Paddle reads the longest lines both ways and turns the text,
  // Vision reads turned text itself.
  const upsideDown = await sampleImage.rotateAsync(180);
  const turnedBack = await ocr.recognize(upsideDown, {
    readingOrder: 'blocks',
  });
  const plainBlocks = await ocr.recognize(sampleImage, {
    readingOrder: 'blocks',
  });
  const firstLine = allLines(turnedBack)[0];
  check(
    'upside-down label reads in order',
    similarity(turnedBack.text, plainBlocks.text) > 0.9 &&
      firstLine != null &&
      /состав/i.test(firstLine.text) &&
      firstLine.boundingBox.y > 0.5,
    {
      similarity: similarity(turnedBack.text, plainBlocks.text),
      first: firstLine?.text,
      firstBox: firstLine?.boundingBox,
      angle: firstLine?.angle,
    },
  );
  if (ocr.engine === 'paddle') {
    const without = await ocr.recognize(upsideDown, {
      textlineOrientation: false,
      output: 'text',
    });
    check('textlineOrientation: false reads it as is', true, {
      similarity: similarity(without.text, plainBlocks.text),
    });
  }

  // ─── ROI ───────────────────────────────────────────────────────────────
  const roi = {
    x: 0,
    y: 0.6,
    width: 1,
    height: 0.4,
    unit: 'normalized' as const,
  };
  const cropped = await ocr.recognize(upright, {
    roi,
    readingOrder: 'rows',
    diagnostics: true,
  });
  const inside = allLines(cropped).every(
    l =>
      l.boundingBox.y >= roi.y - 0.02 &&
      l.boundingBox.y + l.boundingBox.height <= roi.y + roi.height + 0.02,
  );
  check(
    'roi: same image size, boxes inside the roi',
    cropped.image.width === base.image.width &&
      inside &&
      allLines(cropped).length > 0,
    {
      text: cropped.text,
      input: [
        cropped.diagnostics?.inputWidth,
        cropped.diagnostics?.inputHeight,
      ],
      boxes: boxMatch(base, cropped),
    },
  );
  const view = {
    width: base.image.width / 4,
    height: base.image.height / 4,
    resizeMode: 'contain' as const,
  };
  const viaView = await ocr.recognize(upright, {
    roi: {
      x: 0,
      y: 0.6 * view.height,
      width: view.width,
      height: 0.4 * view.height,
      unit: 'pixel',
      view,
    },
    readingOrder: 'rows',
  });
  check('roi in view points (contain)', viaView.text === cropped.text, {
    text: viaView.text,
  });
  await expectError('roi outside', 'invalid-argument', () =>
    ocr.recognize(upright, {
      roi: { x: 1.2, y: 0, width: 0.3, height: 1, unit: 'normalized' },
    }),
  );
  await expectError('empty roi', 'invalid-argument', () =>
    ocr.recognize(upright, {
      roi: { x: 0, y: 0, width: 0, height: 1, unit: 'normalized' },
    }),
  );

  // ─── Output and order ──────────────────────────────────────────────────
  const textOnly = await ocr.recognize(upright, {
    output: 'text',
    readingOrder: 'rows',
  });
  check(
    'output text: no blocks, same text',
    textOnly.blocks.length === 0 && textOnly.text === base.text,
  );
  const linesOnly = await ocr.recognize(upright, { output: 'lines' });
  check(
    'output lines: no words',
    allLines(linesOnly).every(l => l.elements.length === 0),
  );
  const words = allLines(base).flatMap(l => l.elements);
  check(
    'output elements: words with boxes',
    words.length > 0 && words.every(e => e.boundingBox.width > 0),
    {
      words: words.length,
      first: words
        .slice(0, 3)
        .map(e => ({ text: e.text, confidence: e.confidence })),
    },
  );
  const blocks = await ocr.recognize(upright, { readingOrder: 'blocks' });
  check('readingOrder blocks', blocks.blocks.length > 0, {
    blocks: blocks.blocks.length,
    text: blocks.text.slice(0, 120),
  });
  const plain = await ocr.recognizeText(upright, { readingOrder: 'rows' });
  check('recognizeText', plain === base.text);

  // ─── Frames ────────────────────────────────────────────────────────────
  const dev = getOcrDevTools();
  for (const orientation of ['up', 'left', 'right', 'down'] as const) {
    const pointer = dev.createTestFrame(upright, 1920, orientation);
    try {
      const info = dev.getTestFrameInfo(pointer);
      const r = ocr.recognizer.recognizeFrame(pointer, orientation, {
        readingOrder: 'rows',
      });
      check(
        `frame ${orientation}`,
        r.image.width >= r.image.height && similarity(r.text, base.text) > 0.85,
        {
          info,
          image: r.image,
          similarity: similarity(r.text, base.text),
          boxes: boxMatch(base, r),
        },
      );
      if (orientation === 'left') {
        const fr = ocr.recognizer.recognizeFrame(pointer, orientation, {
          roi: { x: 0, y: 0.6, width: 1, height: 0.4 },
          readingOrder: 'rows',
        });
        check('frame roi', boxMatch(cropped, fr).matched > 0, {
          boxes: boxMatch(cropped, fr),
          text: fr.text.slice(0, 60),
        });
      }
    } finally {
      dev.releaseTestFrame(pointer);
    }
  }
  const meter = createFrameMeter();
  const pointer = dev.createTestFrame(upright, 1920, 'left');
  try {
    const area = { x: 0.1, y: 0.1, width: 0.8, height: 0.8 };
    const q1 = meter.measure(pointer, 'left', area);
    const q2 = meter.measure(pointer, 'left', area);
    meter.reset();
    const q3 = meter.measure(pointer, 'left');
    check(
      'frame meter',
      q1.motion === 1 && q2.motion === 0 && q3.motion === 1 && q1.sharpness > 0,
      { q1, q2, q3 },
    );
    const t0 = Date.now();
    for (let i = 0; i < 20; i++) {
      meter.measure(pointer, 'left', area);
    }
    check('frame meter speed', true, { msPerCall: (Date.now() - t0) / 20 });
  } finally {
    dev.releaseTestFrame(pointer);
    meter.dispose();
  }

  // ─── Cancel and dispose ────────────────────────────────────────────────
  const aborted = new AbortController();
  aborted.abort();
  await expectError('aborted before start', 'cancelled', () =>
    ocr.recognize(upright, { signal: aborted.signal }),
  );
  const other = createOcr({ languages: LANGUAGES });
  await other.prepare({ warmUp: false });
  other.dispose();
  await expectError('after dispose', 'disposed', () =>
    other.recognize(upright),
  );
  ocr.dispose();

  // ─── Models ────────────────────────────────────────────────────────────
  if (options.download) {
    const store = getModelStore();
    const progress: number[] = [];
    const t0 = Date.now();
    await configureModels({ source: 'remote' });
    try {
      // Android goes through the language API; on iOS no engine uses packs yet, so the store is
      // driven directly.
      const r =
        Platform.OS === 'android'
          ? await prepare(['de'], {
              onProgress: p => progress.push(p.fraction),
            })
          : await store.download(['en'], p => progress.push(p.fraction), 0);
      const packId = Platform.OS === 'android' ? 'latin' : 'en';
      check(
        `download ${packId}`,
        r.downloadedBytes > 0 && store.getPackStatus(packId) === 'installed',
        {
          result: r,
          ms: Date.now() - t0,
          progressCalls: progress.length,
          last: progress[progress.length - 1],
        },
      );
      const again =
        Platform.OS === 'android'
          ? await prepare(['de'])
          : await store.download(['en'], () => {}, 0);
      check('download again is a no-op', again.downloadedBytes === 0, {
        again,
      });
      await store.remove([packId]);
      check(`remove ${packId}`, store.getPackStatus(packId) === 'missing', {
        status: store.getPackStatus(packId),
      });
      check('prune', true, { freed: await store.prune() });
      if (Platform.OS === 'ios') {
        // PaddleOCR on iOS: only in builds with GlyphOcr_paddleOnIos=1.
        let paddle: Ocr | undefined;
        try {
          paddle = createOcr({ languages: ['ru', 'en'], engine: 'paddle' });
        } catch (e) {
          log(
            `skip Paddle on iOS: ${e instanceof OcrError ? e.code : String(e)}`,
          );
        }
        if (paddle) {
          await paddle.prepare();
          const read = await paddle.recognize(upright, {
            readingOrder: 'rows',
          });
          const missed = SAMPLE_WORDS.filter(
            w => !read.text.toLowerCase().includes(w),
          );
          check('Paddle on iOS reads the label', missed.length === 0, {
            missed,
            text: read.text.slice(0, 80),
            timings: read.timings,
          });
          const paddleTurned = await paddle.recognize(upsideDown, {
            readingOrder: 'blocks',
          });
          check(
            'Paddle on iOS reads it upside down',
            /состав/i.test(allLines(paddleTurned)[0]?.text ?? ''),
            { first: allLines(paddleTurned)[0]?.text },
          );
          paddle.dispose();
          await store.remove(['eslav']);
        }
      }
      if (Platform.OS === 'android') {
        // PP-OCRv6 tiny, the multilingual pack: English and Chinese with 40 Latin languages.
        const multi = createOcr({ languages: ['en'], paddlePack: 'multi' });
        await multi.prepare();
        const read = await multi.recognize(upright, { readingOrder: 'rows' });
        check(
          'PP-OCRv6 multi pack reads English',
          multi.packId === 'multi' &&
            /water, sugar, citric acid/.test(read.text),
          { text: read.text.slice(-80) },
        );
        multi.dispose();
        await store.remove(['multi']);
      }
    } catch (e) {
      check('download', false, { error: String(e) });
    } finally {
      await configureModels({});
    }
  }

  return `${failed} failed of ${total}`;
}

function allLines(r: OcrResult): OcrLine[] {
  return r.blocks.flatMap(b => b.lines);
}

/** Lines with the same text in both results, and how close their boxes are (IoU, normalized). */
function boxMatch(a: OcrResult, b: OcrResult) {
  const bl = allLines(b);
  const ious: number[] = [];
  for (const la of allLines(a)) {
    const lb = bl.find(l => l.text === la.text);
    if (lb) {
      ious.push(iou(la.boundingBox, lb.boundingBox));
    }
  }
  ious.sort((x, y) => x - y);
  return {
    matched: ious.length,
    of: allLines(a).length,
    minIoU: Number((ious[0] ?? 0).toFixed(3)),
    medianIoU: Number((ious[Math.floor(ious.length / 2)] ?? 0).toFixed(3)),
  };
}

type Rect = { x: number; y: number; width: number; height: number };

function iou(a: Rect, b: Rect) {
  const x0 = Math.max(a.x, b.x);
  const y0 = Math.max(a.y, b.y);
  const x1 = Math.min(a.x + a.width, b.x + b.width);
  const y1 = Math.min(a.y + a.height, b.y + b.height);
  const inter = Math.max(0, x1 - x0) * Math.max(0, y1 - y0);
  return inter / (a.width * a.height + b.width * b.height - inter);
}

/** 1 - normalized edit distance. */
function similarity(a: string, b: string) {
  if (a === b) {
    return 1;
  }
  const m = a.length;
  const n = b.length;
  let prev = Array.from({ length: n + 1 }, (_, i) => i);
  for (let i = 1; i <= m; i++) {
    const cur = [i];
    for (let j = 1; j <= n; j++) {
      cur[j] = Math.min(
        prev[j]! + 1,
        cur[j - 1]! + 1,
        prev[j - 1]! + (a[i - 1] === b[j - 1] ? 0 : 1),
      );
    }
    prev = cur;
  }
  return Number((1 - prev[n]! / Math.max(m, n, 1)).toFixed(3));
}

/* eslint-disable no-bitwise */
function decodeBase64(base64: string): Uint8Array<ArrayBuffer> {
  const alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const clean = base64.replace(/[=]+$/, '');
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
  let bits = 0;
  let value = 0;
  let o = 0;
  for (const c of clean) {
    value = (value << 6) | alphabet.indexOf(c);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = (value >> bits) & 0xff;
    }
  }
  return out;
}
/* eslint-enable no-bitwise */
