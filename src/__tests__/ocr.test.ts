import type { LanguageResolution, OcrEngine } from '../specs/Ocr.nitro';

/** Paddle packs of the fake mockFactory: the first one covering every language wins. */
const PACKS: Record<string, string[]> = {
  en: ['en'],
  eslav: ['ru', 'uk', 'be', 'en'],
  latin: ['de', 'fr', 'en'],
};

const created: FakeRecognizer[] = [];

class FakeRecognizer {
  isLoaded = false;
  isReady = true;
  disposed = false;
  cancelled: number[] = [];
  /** Resolvers of pending recognitions, by request id. */
  pending = new Map<number, () => void>();
  constructor(
    readonly engine: OcrEngine,
    readonly languages: string[],
    readonly packId: string | undefined,
  ) {
    created.push(this);
  }
  load = jest.fn(async () => {
    this.isLoaded = true;
    return { downloadedBytes: 0, loadMs: 1, warmUpMs: 0 };
  });
  recognizeUri = jest.fn(
    (uri: string, _options: unknown, requestId: number) =>
      new Promise((resolve, reject) => {
        if (uri === 'slow') {
          this.pending.set(requestId, () =>
            reject(new Error('[ocr:cancelled] Cancelled')),
          );
          return;
        }
        resolve({ text: `text of ${uri}`, blocks: [] });
      }),
  );
  cancel = jest.fn((requestId: number) => {
    this.cancelled.push(requestId);
    this.pending.get(requestId)?.();
  });
  dispose = jest.fn(() => {
    this.disposed = true;
  });
}

const mockFactory = {
  defaultEngine: 'paddle' as OcrEngine,
  resolveLanguages: jest.fn(
    (engine: OcrEngine, languages: string[]): LanguageResolution => {
      if (engine === 'vision') {
        return {
          engine,
          languages,
          engineLanguages: languages,
          unsupported: [],
        };
      }
      const packId = Object.keys(PACKS).find(p =>
        languages.every(l => PACKS[p]!.includes(l)),
      );
      const unknown = languages.filter(
        l => !Object.values(PACKS).flat().includes(l),
      );
      return {
        engine,
        languages,
        engineLanguages: [],
        packId,
        // Like the native side: either the unknown tags, or the ones the first pack misses.
        unsupported: packId
          ? []
          : unknown.length
            ? unknown
            : languages.slice(1),
      };
    },
  ),
  createRecognizer: jest.fn(
    (
      engine: OcrEngine,
      languages: string[],
      _words: string[],
      packId?: string,
    ) => new FakeRecognizer(engine, languages, packId),
  ),
  getSupportedLanguages: jest.fn(() => []),
  models: {
    configure: jest.fn(),
    download: jest.fn(async (packIds: string[]) => ({
      downloadedBytes: 100,
      packIds,
    })),
    cancel: jest.fn(),
    getPackStatus: jest.fn((_packId: string) => 'installed'),
  },
};

jest.mock('react-native-nitro-modules', () => ({
  NitroModules: { createHybridObject: () => mockFactory },
}));

// Imported after the mock.
const ocrModule = require('../ocr') as typeof import('../ocr');
const {
  createOcr,
  recognize,
  prepare,
  isReady,
  getSharedOcr,
  retainSharedOcr,
} = ocrModule;

beforeEach(() => {
  created.length = 0;
  jest.clearAllMocks();
});

describe('createOcr', () => {
  it('picks the pack covering the languages and prepares on first use', async () => {
    const ocr = createOcr({ languages: ['ru', 'en'] });
    expect(ocr.engine).toBe('paddle');
    expect(ocr.packId).toBe('eslav');
    const r = await ocr.recognize('/a.jpg');
    expect(r.text).toBe('text of /a.jpg');
    expect(created[0]!.load).toHaveBeenCalledTimes(1);
    // Recognizing again does not load again.
    await ocr.recognizeText('/b.jpg');
    expect(created[0]!.load).toHaveBeenCalledTimes(1);
    expect(created[0]!.recognizeUri.mock.calls[1]![1]).toEqual({
      output: 'text',
    });
  });

  it('copies array-likes before they reach Nitro', () => {
    createOcr({ languages: Object.freeze(['ru']), customWords: ['сахар'] });
    const call = mockFactory.createRecognizer.mock.calls[0]!;
    expect(Array.isArray(call[1])).toBe(true);
    expect(call[2]).toEqual(['сахар']);
  });

  it('suggests one instance per pack when no pack covers all languages', () => {
    let error: unknown;
    try {
      createOcr({ languages: ['ru', 'de'] });
    } catch (e) {
      error = e;
    }
    expect(error).toMatchObject({
      code: 'language-not-supported',
      details: {
        suggestion: [
          { languages: ['ru'], packId: 'eslav' },
          { languages: ['de'], packId: 'latin' },
        ],
      },
    });
  });

  it('gives no suggestion for a language nothing reads', () => {
    expect(() => createOcr({ languages: ['xx'] })).toThrow(
      expect.objectContaining({
        code: 'language-not-supported',
        details: expect.objectContaining({ suggestion: undefined }),
      }),
    );
  });

  it('rejects with disposed after dispose', async () => {
    const ocr = createOcr({ languages: ['en'] });
    ocr.dispose();
    ocr.dispose();
    expect(created[0]!.dispose).toHaveBeenCalledTimes(1);
    await expect(ocr.recognize('/a.jpg')).rejects.toMatchObject({
      code: 'disposed',
    });
    await expect(ocr.prepare()).rejects.toMatchObject({ code: 'disposed' });
  });

  it('lets a failed prepare be retried', async () => {
    const ocr = createOcr({ languages: ['en'] });
    created[0]!.load.mockRejectedValueOnce(
      new Error('[ocr:download-failed] offline'),
    );
    await expect(ocr.prepare()).rejects.toMatchObject({
      code: 'download-failed',
    });
    await expect(ocr.prepare()).resolves.toMatchObject({ loadMs: 1 });
  });
});

describe('cancelling', () => {
  it('does not start when the signal is already aborted', async () => {
    const ocr = createOcr({ languages: ['en'] });
    await ocr.prepare();
    const c = new AbortController();
    c.abort();
    await expect(
      ocr.recognize('/a.jpg', { signal: c.signal }),
    ).rejects.toMatchObject({ code: 'cancelled' });
    expect(created[0]!.recognizeUri).not.toHaveBeenCalled();
  });

  it('cancels the native request of a running call', async () => {
    const ocr = createOcr({ languages: ['en'] });
    await ocr.prepare();
    const c = new AbortController();
    const running = ocr.recognize('slow', { signal: c.signal });
    await Promise.resolve();
    c.abort();
    await expect(running).rejects.toMatchObject({ code: 'cancelled' });
    const requestId = created[0]!.recognizeUri.mock.calls[0]![2];
    expect(created[0]!.cancelled).toEqual([requestId]);
  });
});

describe('shared instances', () => {
  it('reuses one instance per engine, pack and languages', () => {
    const a = getSharedOcr({ languages: ['fr'] });
    const b = getSharedOcr({ languages: ['fr'] });
    expect(a).toBe(b);
  });

  it('keeps one idle instance and frees older ones', async () => {
    await recognize('/a.jpg', { languages: ['uk'] });
    await recognize('/a.jpg', { languages: ['be'] });
    await recognize('/a.jpg', { languages: ['be', 'en'] });
    const [uk, be, beEn] = created;
    expect(uk!.disposed).toBe(true);
    expect(be!.disposed).toBe(true);
    expect(beEn!.disposed).toBe(false);
  });

  it('never frees an instance a hook holds', async () => {
    const held = getSharedOcr({ languages: ['de'] });
    const release = retainSharedOcr(held);
    await recognize('/a.jpg', { languages: ['de', 'fr'] });
    await recognize('/a.jpg', { languages: ['de', 'en'] });
    expect(created.find(r => r.languages.join() === 'de')!.disposed).toBe(
      false,
    );
    release();
    release();
    await recognize('/a.jpg', { languages: ['fr', 'en'] });
    expect(created.find(r => r.languages.join() === 'de')!.disposed).toBe(true);
  });
});

describe('models', () => {
  it('downloads the pack of the languages', async () => {
    await expect(prepare(['ru'])).resolves.toEqual({
      downloadedBytes: 100,
      packIds: ['eslav'],
    });
    expect(mockFactory.models.download.mock.calls[0]![0]).toEqual(['eslav']);
  });

  it('needs nothing for Vision', async () => {
    await expect(prepare(['ru'], { engine: 'vision' })).resolves.toEqual({
      downloadedBytes: 0,
      packIds: [],
    });
    expect(mockFactory.models.download).not.toHaveBeenCalled();
  });

  it('rejects languages nothing reads', async () => {
    await expect(prepare(['xx'])).rejects.toMatchObject({
      code: 'language-not-supported',
    });
  });

  it('reports readiness from the pack status', () => {
    expect(isReady('ru')).toBe(true);
    mockFactory.models.getPackStatus.mockReturnValueOnce('missing');
    expect(isReady(['ru', 'en'])).toBe(false);
    expect(isReady('xx')).toBe(false);
    expect(isReady('ru', 'vision')).toBe(true);
  });
});
