import { NitroModules } from 'react-native-nitro-modules';

import { OcrError, toOcrError } from './errors';
import { type OcrSource, recognizeSource } from './sources';
import type {
  DownloadResult,
  LanguageResolution,
  LoadResult,
  ModelManifest,
  ModelStoreConfig,
  OcrEngine,
  OcrFactory,
  OcrModelStore,
  OcrRecognizer,
  OcrResult,
  PrepareProgress,
  RecognizeOptions,
  SupportedLanguage,
} from './specs/Ocr.nitro';

/** `auto`: Vision on iOS, Paddle on Android. */
export type EngineOption = 'auto' | 'vision' | 'paddle';

export interface CreateOcrOptions {
  /** BCP-47 in priority order: `['ru', 'en']`. Decides the Vision languages and the Paddle pack. */
  languages: readonly string[];
  /** Default `auto`. */
  engine?: EngineOption;
  /** Paddle: use this pack instead of the first one covering `languages` (e.g. `cyrillic`). */
  paddlePack?: string;
  /** Paddle: inference threads. Default 4, the best measured on Pixel 6a. */
  threads?: number;
  /** Vision: words to prefer when `usesLanguageCorrection` is on. Ignored by Paddle. */
  customWords?: readonly string[];
}

export interface PrepareOptions {
  onProgress?: (progress: PrepareProgress) => void;
  signal?: AbortSignal;
}

export interface CallOptions extends RecognizeOptions {
  signal?: AbortSignal;
}

export interface Ocr {
  readonly engine: OcrEngine;
  readonly languages: readonly string[];
  readonly packId: string | undefined;
  /** Models are on disk (always true for Vision). */
  readonly isReady: boolean;
  /** Models are loaded into memory. */
  readonly isLoaded: boolean;
  /** The native object, for worklets: `recognizer.recognizeFrame(...)`. */
  readonly recognizer: OcrRecognizer;
  /** Download what is missing, load the models, warm the engine up (default `warmUp: true`). */
  prepare(options?: PrepareOptions & { warmUp?: boolean }): Promise<LoadResult>;
  /** Prepares on the first call if needed. */
  recognize(source: OcrSource, options?: CallOptions): Promise<OcrResult>;
  /** Same pipeline with `output: 'text'`: no geometry crosses JSI. */
  recognizeText(source: OcrSource, options?: CallOptions): Promise<string>;
  /** Frees the models. Later calls reject with `disposed`. */
  dispose(): void;
}

let factory: OcrFactory | undefined;

/** @internal */
export function getFactory(): OcrFactory {
  factory ??= NitroModules.createHybridObject<OcrFactory>('OcrFactory');
  return factory;
}

/** Native calls that throw synchronously throw `[ocr:…]` errors too. */
function sync<T>(call: () => T): T {
  try {
    return call();
  } catch (e) {
    throw toOcrError(e);
  }
}

let nextRequestId = 1;

/** Runs `call` with a fresh request id and maps `signal` to native `cancel(id)`. */
async function withSignal<T>(
  signal: AbortSignal | undefined,
  cancel: (requestId: number) => void,
  call: (requestId: number) => Promise<T>,
): Promise<T> {
  if (signal?.aborted) {
    throw new OcrError('cancelled', 'Aborted before start');
  }
  const requestId = nextRequestId++;
  const onAbort = () => cancel(requestId);
  signal?.addEventListener('abort', onAbort);
  try {
    return await call(requestId);
  } catch (e) {
    throw toOcrError(e);
  } finally {
    signal?.removeEventListener('abort', onAbort);
  }
}

function resolveEngine(engine: EngineOption | undefined): OcrEngine {
  return engine == null || engine === 'auto'
    ? getFactory().defaultEngine
    : engine;
}

/**
 * `language-not-supported` with `details.suggestion`: when no single pack covers all languages
 * but each one alone is covered, one instance per pack (`['ru', 'de']` → eslav + latin).
 */
function notSupported(engine: OcrEngine, r: LanguageResolution): OcrError {
  const f = getFactory();
  const byPack = new Map<string, string[]>();
  let all = true;
  for (const language of r.languages) {
    try {
      const one = f.resolveLanguages(engine, [language]);
      if (one.unsupported.length > 0) {
        all = false;
      } else {
        const key = one.packId ?? engine;
        byPack.set(key, [...(byPack.get(key) ?? []), language]);
      }
    } catch {
      all = false;
    }
  }
  const suggestion =
    all && byPack.size > 1
      ? [...byPack].map(([packId, languages]) => ({ languages, packId }))
      : undefined;
  return new OcrError(
    'language-not-supported',
    `${engine} cannot read ${r.unsupported.join(', ')}${
      suggestion ? ' together with the others' : ''
    }`,
    { engine, unsupported: r.unsupported, suggestion },
  );
}

class OcrImpl implements Ocr {
  readonly recognizer: OcrRecognizer;
  private loading?: Promise<LoadResult>;
  private disposed = false;

  constructor(options: CreateOcrOptions) {
    const f = getFactory();
    const engine = resolveEngine(options.engine);
    // A plain copy: MobX observable arrays are array-likes, and Nitro rejects them.
    const languages = Array.from(options.languages);
    const resolution = sync(() =>
      f.resolveLanguages(engine, languages, options.paddlePack),
    );
    if (resolution.unsupported.length > 0) {
      throw notSupported(engine, resolution);
    }
    // A plain copy for customWords too: MobX arrays.
    const customWords = Array.from(options.customWords ?? []);
    this.recognizer = sync(() =>
      f.createRecognizer(
        engine,
        resolution.languages,
        customWords,
        resolution.packId,
        options.threads,
      ),
    );
  }

  get engine() {
    return this.recognizer.engine;
  }
  get languages() {
    return this.recognizer.languages;
  }
  get packId() {
    return this.recognizer.packId;
  }
  get isReady() {
    return this.recognizer.isReady;
  }
  get isLoaded() {
    return this.recognizer.isLoaded;
  }

  prepare(
    options: PrepareOptions & { warmUp?: boolean } = {},
  ): Promise<LoadResult> {
    if (this.disposed) {
      return Promise.reject(
        new OcrError('disposed', 'This Ocr instance was disposed'),
      );
    }
    if (this.loading == null) {
      this.loading = withSignal(
        options.signal,
        id => this.recognizer.cancel(id),
        id =>
          this.recognizer.load(
            options.warmUp ?? true,
            options.onProgress ?? noop,
            id,
          ),
      ).catch(e => {
        this.loading = undefined; // allow a retry
        throw e;
      });
    }
    return this.loading;
  }

  async recognize(
    source: OcrSource,
    options: CallOptions = {},
  ): Promise<OcrResult> {
    this.assertAlive();
    if (!this.recognizer.isLoaded) {
      await this.prepare({ signal: options.signal, warmUp: false });
    }
    const { signal, ...native } = options;
    return withSignal(
      signal,
      id => this.recognizer.cancel(id),
      id => recognizeSource(this.recognizer, source, native, id),
    );
  }

  async recognizeText(
    source: OcrSource,
    options: CallOptions = {},
  ): Promise<string> {
    return (await this.recognize(source, { ...options, output: 'text' })).text;
  }

  dispose() {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.recognizer.dispose();
  }

  private assertAlive() {
    if (this.disposed) {
      throw new OcrError('disposed', 'This Ocr instance was disposed');
    }
  }
}

function noop() {}

export function createOcr(options: CreateOcrOptions): Ocr {
  return new OcrImpl(options);
}

// ─── One-shot API over a small cache of instances ─────────────────────────

export interface OneShotOptions extends CallOptions {
  /** Default `['en']`. */
  languages?: readonly string[];
  engine?: EngineOption;
  paddlePack?: string;
}

interface Shared {
  ocr: Ocr;
  refs: number;
}

/**
 * Instances shared by `recognize()` and `useOcr()`, keyed by engine, pack, threads and languages.
 * Referenced ones (mounted hooks, running calls) are never evicted; up to `IDLE_LIMIT` idle ones
 * stay loaded, so going back to a screen does not reload the models.
 */
const shared = new Map<string, Shared>();
const IDLE_LIMIT = 1;

function sharedKey(o: CreateOcrOptions) {
  return [
    resolveEngine(o.engine),
    o.paddlePack ?? '',
    o.threads ?? '',
    Array.from(o.languages).join(','),
    Array.from(o.customWords ?? []).join('\u0001'),
  ].join('|');
}

/** @internal Without a reference: `recognize()` and the first render of `useOcr()`. */
export function getSharedOcr(options: CreateOcrOptions): Ocr {
  const key = sharedKey(options);
  let entry = shared.get(key);
  if (entry == null) {
    entry = { ocr: createOcr(options), refs: 0 };
    shared.set(key, entry);
    evictIdle(key);
  } else {
    // Map order is the LRU order.
    shared.delete(key);
    shared.set(key, entry);
  }
  return entry.ocr;
}

/** @internal `useOcr()` holds a reference while mounted. Returns the release function. */
export function retainSharedOcr(ocr: Ocr): () => void {
  const entry = [...shared.values()].find(e => e.ocr === ocr);
  if (entry == null) {
    return noop;
  }
  entry.refs++;
  let released = false;
  return () => {
    if (released) {
      return;
    }
    released = true;
    entry.refs--;
    evictIdle();
  };
}

function evictIdle(keep?: string) {
  const idle = [...shared.entries()].filter(
    ([k, e]) => e.refs === 0 && k !== keep,
  );
  for (const [key, entry] of idle.slice(
    0,
    Math.max(0, idle.length - IDLE_LIMIT),
  )) {
    shared.delete(key);
    entry.ocr.dispose();
  }
}

export async function recognize(
  source: OcrSource,
  options: OneShotOptions = {},
): Promise<OcrResult> {
  const { languages = ['en'], engine, paddlePack, ...call } = options;
  const ocr = getSharedOcr({ languages, engine, paddlePack });
  const release = retainSharedOcr(ocr); // not evicted while running
  try {
    return await ocr.recognize(source, call);
  } finally {
    release();
  }
}

export async function recognizeText(
  source: OcrSource,
  options: OneShotOptions = {},
): Promise<string> {
  return (await recognize(source, { ...options, output: 'text' })).text;
}

// ─── Models ───────────────────────────────────────────────────────────────

export interface ConfigureModelsOptions extends ModelStoreConfig {
  /** Fetched once with `headers`; replaces `manifest`. */
  manifestUrl?: string;
}

/** Call once at startup, before `prepare()`. */
export async function configureModels(
  options: ConfigureModelsOptions,
): Promise<void> {
  const { manifestUrl, ...config } = options;
  if (manifestUrl != null) {
    let response: Response;
    try {
      response = await fetch(manifestUrl, { headers: config.headers });
    } catch (e) {
      throw new OcrError(
        'download-failed',
        `Manifest: ${String(e)}`,
        { url: manifestUrl },
        e,
      );
    }
    if (!response.ok) {
      throw new OcrError(
        'download-failed',
        `Manifest: HTTP ${response.status}`,
        {
          status: response.status,
          url: manifestUrl,
        },
      );
    }
    config.manifest = (await response.json()) as ModelManifest;
  }
  sync(() => getFactory().models.configure(config));
}

/**
 * Downloads and verifies the models `languages` need, without loading them.
 * Resolves at once for Vision. Downloads of the same file are shared between calls.
 */
export function prepare(
  languages: readonly string[],
  options: PrepareOptions & { engine?: EngineOption; paddlePack?: string } = {},
): Promise<DownloadResult> {
  try {
    const f = getFactory();
    const engine = resolveEngine(options.engine);
    const r = sync(() =>
      f.resolveLanguages(engine, Array.from(languages), options.paddlePack),
    );
    if (r.unsupported.length > 0) {
      return Promise.reject(notSupported(engine, r));
    }
    if (r.packId == null) {
      return Promise.resolve({ downloadedBytes: 0, packIds: [] });
    }
    const packId = r.packId;
    return withSignal(
      options.signal,
      id => f.models.cancel(id),
      id => f.models.download([packId], options.onProgress ?? noop, id),
    );
  } catch (e) {
    return Promise.reject(toOcrError(e));
  }
}

/** Whether recognition can start without downloading anything. */
export function isReady(
  language: string | readonly string[],
  engine?: EngineOption,
): boolean {
  const f = getFactory();
  const e = resolveEngine(engine);
  let r: LanguageResolution;
  try {
    r = f.resolveLanguages(
      e,
      typeof language === 'string' ? [language] : Array.from(language),
    );
  } catch {
    return false;
  }
  if (r.unsupported.length > 0) {
    return false;
  }
  if (r.packId == null) {
    return true;
  }
  const status = f.models.getPackStatus(r.packId);
  return status === 'installed' || status === 'embedded';
}

/**
 * The model store: `getPackStatus`, `remove` and `prune` for a settings screen, `manifest` and
 * `directory`. `configureModels`, `prepare` and `isReady` cover the rest.
 */
export function getModelStore(): OcrModelStore {
  return getFactory().models;
}

/** Every engine compiled into this build unless `engine` is given. */
export function getSupportedLanguages(
  engine?: EngineOption,
): SupportedLanguage[] {
  return sync(() =>
    getFactory().getSupportedLanguages(
      engine == null ? undefined : resolveEngine(engine),
    ),
  );
}
