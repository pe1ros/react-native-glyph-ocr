import { NitroModules } from 'react-native-nitro-modules';

import type { GlyphOcrDevTools } from '../specs/OcrDevTools.nitro';

export type {
  DeviceSummary,
  DevTuning,
  GlyphOcrDevTools,
  PaddleRuntimeKind,
  TestFrameInfo,
} from '../specs/OcrDevTools.nitro';

let tools: GlyphOcrDevTools | undefined;

/** Bench helpers. Not for app code: the API may change in any release. */
export function getOcrDevTools(): GlyphOcrDevTools {
  tools ??=
    NitroModules.createHybridObject<GlyphOcrDevTools>('GlyphOcrDevTools');
  return tools;
}
