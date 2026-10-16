import { NitroModules } from 'react-native-nitro-modules';

import type { PurelyOcr } from './specs/PurelyOcr.nitro';

export type {
  DeviceSummary,
  ModelLoadInfo,
  OcrEngine,
  OcrLine,
  OcrResult,
  PaddleModelConfig,
  PaddleOptions,
  PurelyOcr,
  VisionOptions,
} from './specs/PurelyOcr.nitro';

let instance: PurelyOcr | undefined;

/** Lazily creates the native OCR object. */
export function getPurelyOcr(): PurelyOcr {
  if (instance == null) {
    instance = NitroModules.createHybridObject<PurelyOcr>('PurelyOcr');
  }
  return instance;
}
