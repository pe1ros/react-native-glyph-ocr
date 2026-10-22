import {
  type ConfigPlugin,
  createRunOncePlugin,
  withGradleProperties,
  withPodfile,
} from '@expo/config-plugins';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export interface GlyphOcrPluginProps {
  /**
   * Android: model packs of `models/manifest.json` to download at build time and ship in the APK
   * (`GlyphOcr_embedPacks`), e.g. `['eslav']`. Without them the models are downloaded on the first
   * `prepare()`. Each pack adds 13.7–22.4 MB.
   */
  embedPacks?: string[];
  /** Android: compile ML Kit for `react-native-glyph-ocr/dev` (`GlyphOcr_devMlKit`, +12.5 MB). */
  devMlKit?: boolean;
  /**
   * iOS: also build PaddleOCR on ONNX Runtime (`GlyphOcr_paddleOnIos`), for the languages Vision
   * does not read. Adds onnxruntime-objc to the app.
   */
  paddleOnIos?: boolean;
}

type GradleProperty =
  | { type: 'property'; key: string; value: string }
  | { type: 'comment'; value: string }
  | { type: 'empty' };

const PACKAGE = 'react-native-glyph-ocr';

/** Pack ids of the manifest shipped with the package. */
export function getPackIds(): string[] {
  const manifest = JSON.parse(
    readFileSync(
      join(__dirname, '..', '..', 'models', 'manifest.json'),
      'utf8',
    ),
  ) as { packs: { id: string }[] };
  return manifest.packs.map(p => p.id);
}

/** Replaces the module's build flags in a parsed gradle.properties. */
export function setGradleProperties(
  properties: GradleProperty[],
  props: GlyphOcrPluginProps,
): GradleProperty[] {
  const known = getPackIds();
  const unknown = (props.embedPacks ?? []).filter(p => !known.includes(p));
  if (unknown.length > 0) {
    throw new Error(
      `[${PACKAGE}] embedPacks: no pack ${unknown.join(', ')}; available: ${known.join(', ')}`,
    );
  }
  const values: Record<string, string | undefined> = {
    GlyphOcr_embedPacks: props.embedPacks?.length
      ? props.embedPacks.join(',')
      : undefined,
    GlyphOcr_devMlKit: props.devMlKit ? 'true' : undefined,
  };
  const result = properties.filter(
    p => !(p.type === 'property' && p.key in values),
  );
  for (const [key, value] of Object.entries(values)) {
    if (value != null) {
      result.push({ type: 'property', key, value });
    }
  }
  return result;
}

const BEGIN = '# @generated begin react-native-glyph-ocr';
const END = '# @generated end react-native-glyph-ocr';

/** Adds (or removes) what PaddleOCR on iOS needs in the Podfile: the build flag and module maps. */
export function setPodfile(contents: string, paddleOnIos: boolean): string {
  const block = new RegExp(`[ \\t]*${BEGIN}[\\s\\S]*?${END}[^\\n]*\\n?`, 'g');
  let out = contents.replace(block, '');
  if (!paddleOnIos) {
    return out;
  }
  out = `${BEGIN} (flag)\nENV['GlyphOcr_paddleOnIos'] = '1'\n${END} (flag)\n${out}`;
  const anchor =
    /^([ \t]*)(use_expo_modules!|config = use_native_modules!).*$/m;
  const m = anchor.exec(out);
  if (m == null) {
    throw new Error(
      `[${PACKAGE}] paddleOnIos: no use_expo_modules! or use_native_modules! line in the Podfile`,
    );
  }
  const indent = m[1] ?? '';
  const pod = [
    `${indent}${BEGIN} (pod)`,
    `${indent}# ONNX Runtime's Objective-C API is imported from Swift: it needs module maps.`,
    `${indent}pod 'onnxruntime-objc', :modular_headers => true`,
    `${indent}${END} (pod)`,
  ].join('\n');
  const at = m.index + m[0].length;
  return `${out.slice(0, at)}\n${pod}${out.slice(at)}`;
}

const withGlyphOcr: ConfigPlugin<GlyphOcrPluginProps | void> = (
  config,
  props,
) => {
  const options = props ?? {};
  const withGradle = withGradleProperties(config, c => {
    c.modResults = setGradleProperties(c.modResults, options);
    return c;
  });
  return withPodfile(withGradle, c => {
    c.modResults.contents = setPodfile(
      c.modResults.contents,
      options.paddleOnIos === true,
    );
    return c;
  });
};

export default createRunOncePlugin(withGlyphOcr, PACKAGE);
