import withGlyphOcr, { getPackIds, setGradleProperties } from '../index';

describe('Expo config plugin', () => {
  it('knows the packs of the shipped manifest', () => {
    expect(getPackIds()).toEqual(
      expect.arrayContaining(['en', 'eslav', 'cyrillic', 'latin']),
    );
  });

  it('writes the build flags and replaces old values', () => {
    const before = [
      { type: 'property' as const, key: 'android.useAndroidX', value: 'true' },
      { type: 'property' as const, key: 'GlyphOcr_embedPacks', value: 'en' },
    ];
    expect(
      setGradleProperties(before, {
        embedPacks: ['eslav', 'latin'],
        devMlKit: true,
      }),
    ).toEqual([
      { type: 'property', key: 'android.useAndroidX', value: 'true' },
      { type: 'property', key: 'GlyphOcr_embedPacks', value: 'eslav,latin' },
      { type: 'property', key: 'GlyphOcr_devMlKit', value: 'true' },
    ]);
  });

  it('removes the flags when the options are gone', () => {
    expect(
      setGradleProperties(
        [{ type: 'property', key: 'GlyphOcr_embedPacks', value: 'en' }],
        {},
      ),
    ).toEqual([]);
  });

  it('rejects unknown packs', () => {
    expect(() => setGradleProperties([], { embedPacks: ['ru'] })).toThrow(
      /no pack ru/,
    );
  });

  it('registers a gradle.properties mod', async () => {
    const config = withGlyphOcr(
      { name: 'app', slug: 'app' },
      { embedPacks: ['eslav'] },
    );
    const mod = (config as any).mods.android.gradleProperties;
    const result = await mod({
      ...config,
      modResults: [],
      modRequest: { platform: 'android', modName: 'gradleProperties' },
    });
    expect(result.modResults).toEqual([
      { type: 'property', key: 'GlyphOcr_embedPacks', value: 'eslav' },
    ]);
  });
});
