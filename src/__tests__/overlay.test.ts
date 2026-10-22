jest.mock('react-native', () => ({
  Pressable: 'Pressable',
  View: 'View',
  StyleSheet: { create: (s: object) => s, absoluteFill: {} },
}));
jest.mock('react-native-nitro-modules', () => ({ NitroModules: {} }));

const { imagePointToViewPoint, nodeToViewBox, nodesOf } =
  require('../overlay') as typeof import('../overlay');

const image = { width: 2000, height: 1000 };

describe('overlay geometry', () => {
  it('contain letterboxes a wide image in a square view', () => {
    // scale 0.5 → 1000×500 shown, 250 pt bars at top and bottom
    expect(
      imagePointToViewPoint(
        { x: 0, y: 0 },
        { width: 1000, height: 1000 },
        image,
      ),
    ).toEqual({ x: 0, y: 250 });
    expect(
      imagePointToViewPoint(
        { x: 1, y: 1 },
        { width: 1000, height: 1000 },
        image,
      ),
    ).toEqual({ x: 1000, y: 750 });
  });

  it('cover crops the sides', () => {
    // scale 1 → 2000×1000 shown, 500 pt cut on each side
    expect(
      imagePointToViewPoint(
        { x: 0.5, y: 0 },
        { width: 1000, height: 1000 },
        image,
        'cover',
      ),
    ).toEqual({ x: 500, y: 0 });
  });

  it('turns corner points into a rotated box', () => {
    // A 400×100 px line rotated 90° clockwise around (1000, 500): TL is top right.
    const corners = [
      { x: 1050, y: 300 },
      { x: 1050, y: 700 },
      { x: 950, y: 700 },
      { x: 950, y: 300 },
    ].map(p => ({ x: p.x / image.width, y: p.y / image.height }));
    const box = nodeToViewBox(
      { cornerPoints: corners },
      { width: 2000, height: 1000 },
      image,
    )!;
    expect(box.cx).toBeCloseTo(1000);
    expect(box.cy).toBeCloseTo(500);
    expect(box.width).toBeCloseTo(400);
    expect(box.height).toBeCloseTo(100);
    expect(box.angle).toBeCloseTo(90);
  });

  it('skips nodes without four corners', () => {
    expect(
      nodeToViewBox({ cornerPoints: [] }, { width: 1, height: 1 }, image),
    ).toBeUndefined();
  });

  it('lists nodes of each level in order', () => {
    const el = (text: string) => ({ text }) as never;
    const result = {
      blocks: [
        {
          text: 'a b\nc',
          lines: [
            { text: 'a b', elements: [el('a'), el('b')] },
            { text: 'c', elements: [el('c')] },
          ],
        },
        { text: 'd', lines: [{ text: 'd', elements: [el('d')] }] },
      ],
    } as never;
    expect(nodesOf(result, 'blocks').map(n => n.text)).toEqual(['a b\nc', 'd']);
    expect(nodesOf(result, 'lines').map(n => n.text)).toEqual([
      'a b',
      'c',
      'd',
    ]);
    expect(nodesOf(result, 'elements').map(n => n.text)).toEqual([
      'a',
      'b',
      'c',
      'd',
    ]);
  });
});
