import withGlyphOcr, {
  getPackIds,
  setGradleProperties,
  setPodfile,
} from '../index';

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

  it('adds the Paddle flag and module maps to the Podfile, idempotently', () => {
    const podfile = [
      "platform :ios, '16.0'",
      "target 'App' do",
      '  use_expo_modules!',
      '  config = use_native_modules!',
      'end',
      '',
    ].join('\n');
    const once = setPodfile(podfile, true);
    expect(once).toContain("ENV['GlyphOcr_paddleOnIos'] = '1'");
    expect(once).toContain(
      '  use_expo_modules!\n  # @generated begin react-native-glyph-ocr (pod)',
    );
    expect(once).toContain(
      "  pod 'onnxruntime-objc', :modular_headers => true",
    );
    expect(setPodfile(once, true)).toBe(once);
    expect(setPodfile(once, false)).toBe(podfile);
  });

  it('needs a place for the pod line', () => {
    expect(() => setPodfile("target 'App' do\nend\n", true)).toThrow(
      /no use_expo_modules!/,
    );
  });
});
