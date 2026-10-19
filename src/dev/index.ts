import { NitroModules } from 'react-native-nitro-modules';

import type { OcrDevTools } from '../specs/OcrDevTools.nitro';

export type {
  DeviceSummary,
  DevTuning,
  OcrDevTools,
  PaddleRuntimeKind,
  TestFrameInfo,
} from '../specs/OcrDevTools.nitro';

let tools: OcrDevTools | undefined;

/** Bench helpers. Not for app code: the API may change in any release. */
export function getOcrDevTools(): OcrDevTools {
  tools ??= NitroModules.createHybridObject<OcrDevTools>('OcrDevTools');
  return tools;
}
