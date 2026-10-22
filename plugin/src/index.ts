import {
  type ConfigPlugin,
  createRunOncePlugin,
  withGradleProperties,
} from '@expo/config-plugins';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export interface GlyphOcrPluginProps {
  /**
   * Android: model packs of `models/manifest.json` to download at build time and ship in the APK
   * (`GlyphOcr_embedPacks`), e.g. `['eslav']`. Without them the models are downloaded on the first
   * `prepare()`. Each pack adds 12.6–21.4 MB.
   */
  embedPacks?: string[];
  /** Android: compile ML Kit for `react-native-glyph-ocr/dev` (`GlyphOcr_devMlKit`, +12.5 MB). */
  devMlKit?: boolean;
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

const withGlyphOcr: ConfigPlugin<GlyphOcrPluginProps | void> = (
  config,
  props,
) =>
  withGradleProperties(config, c => {
    c.modResults = setGradleProperties(c.modResults, props ?? {});
    return c;
  });

export default createRunOncePlugin(withGlyphOcr, PACKAGE);
