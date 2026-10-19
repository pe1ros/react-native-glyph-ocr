import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { type OcrError, toOcrError } from './errors';
import {
  type CallOptions,
  type CreateOcrOptions,
  getSharedOcr,
  type Ocr,
  retainSharedOcr,
} from './ocr';
import type { OcrSource } from './sources';
import type { OcrResult } from './specs/Ocr.nitro';

export interface UseOcrOptions extends CreateOcrOptions {
  /** Download and load when mounted. Default true. With false, call `prepare()`. */
  autoPrepare?: boolean;
  /** Run one tiny recognition after loading, so the first real one is not slow. Default true. */
  warmUp?: boolean;
}

export type OcrStatus = 'idle' | 'downloading' | 'loading' | 'ready' | 'error';

export interface UseOcrResult {
  status: OcrStatus;
  isReady: boolean;
  /** 0..1 while downloading or loading, otherwise undefined. */
  downloadProgress: number | undefined;
  error: OcrError | undefined;
  /** Waits for preparation, then recognizes. Same function between renders. */
  recognize: (source: OcrSource, options?: CallOptions) => Promise<OcrResult>;
  recognizeText: (source: OcrSource, options?: CallOptions) => Promise<string>;
  /** Starts preparation, or retries it after an error. */
  prepare: () => void;
  /** For `useTextScanner` and worklets. Undefined when the languages are not supported. */
  ocr: Ocr | undefined;
}

export function useOcr(options: UseOcrOptions): UseOcrResult {
  const {
    languages,
    engine,
    paddlePack,
    threads,
    customWords,
    autoPrepare = true,
    warmUp = true,
  } = options;
  // A new array with the same tags every render must not recreate the instance.
  const languagesKey = Array.from(languages).join(',');
  const wordsKey = Array.from(customWords ?? []).join('\u0001');
  const created = useMemo(() => {
    try {
      return {
        ocr: getSharedOcr({
          languages: languagesKey.split(','),
          engine,
          paddlePack,
          threads,
          customWords: wordsKey ? wordsKey.split('\u0001') : undefined,
        }),
        error: undefined,
      };
    } catch (e) {
      return { ocr: undefined, error: toOcrError(e) }; // e.g. language-not-supported
    }
  }, [languagesKey, wordsKey, engine, paddlePack, threads]);
  const ocr = created.ocr;

  const [status, setStatus] = useState<OcrStatus>(() =>
    ocr?.isLoaded ? 'ready' : 'idle',
  );
  const [downloadProgress, setDownloadProgress] = useState<number>();
  const [error, setError] = useState<OcrError>();
  const ocrRef = useRef(created);
  ocrRef.current = created;

  useEffect(() => (ocr ? retainSharedOcr(ocr) : undefined), [ocr]);

  const prepare = useCallback(() => {
    const current = ocr;
    if (current == null) {
      setStatus('error');
      setError(created.error);
      return;
    }
    setError(undefined);
    setStatus(
      current.isLoaded ? 'ready' : current.isReady ? 'loading' : 'downloading',
    );
    current
      .prepare({
        warmUp,
        onProgress: p => {
          if (ocrRef.current.ocr !== current) {
            return;
          }
          setStatus(
            p.phase === 'downloading' || p.phase === 'verifying'
              ? 'downloading'
              : 'loading',
          );
          setDownloadProgress(p.fraction);
        },
      })
      .then(
        () => {
          if (ocrRef.current.ocr !== current) {
            return;
          }
          setStatus('ready');
          setDownloadProgress(undefined);
        },
        (e: unknown) => {
          if (ocrRef.current.ocr !== current) {
            return;
          }
          setStatus('error');
          setDownloadProgress(undefined);
          setError(toOcrError(e));
        },
      );
  }, [ocr, created.error, warmUp]);

  useEffect(() => {
    if (autoPrepare) {
      prepare();
    }
  }, [autoPrepare, prepare]);

  const recognize = useCallback(
    (source: OcrSource, callOptions?: CallOptions) => {
      const { ocr: current, error: createError } = ocrRef.current;
      return current
        ? current.recognize(source, callOptions)
        : Promise.reject(createError);
    },
    [],
  );
  const recognizeText = useCallback(
    async (source: OcrSource, callOptions?: CallOptions) =>
      (await recognize(source, { ...callOptions, output: 'text' })).text,
    [recognize],
  );

  return {
    status,
    isReady: status === 'ready',
    downloadProgress,
    error: error ?? created.error,
    recognize,
    recognizeText,
    prepare,
    ocr,
  };
}
