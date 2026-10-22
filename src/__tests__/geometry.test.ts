jest.mock('react-native-vision-camera', () => ({ CommonResolutions: {} }), {
  virtual: true,
});
jest.mock('react-native-worklets', () => ({}), { virtual: true });
jest.mock('react-native-nitro-modules', () => ({ NitroModules: {} }));

const { viewRectToImageRect, imageRectToViewRect } =
  require('../camera') as typeof import('../camera');

const close = (a: object, b: object) => {
  for (const [k, v] of Object.entries(b)) {
    expect((a as Record<string, number>)[k]).toBeCloseTo(v as number, 6);
  }
};

describe('view ↔ image rects', () => {
  // A 3:4 portrait frame shown in a 9:16 view.
  const view = { width: 900, height: 1600 };
  const image = { width: 1500, height: 2000 };

  it('cover: the view shows the middle of a wider image', () => {
    // scale = max(900/1500, 1600/2000) = 0.8 → 1200×1600 shown, 150 px cut on each side
    close(
      viewRectToImageRect({ x: 0, y: 0, width: 1, height: 1 }, view, image),
      {
        x: 150 / 1200,
        y: 0,
        width: 900 / 1200,
        height: 1,
      },
    );
  });

  it('contain: a rect in the letterbox is clamped to the image', () => {
    // scale = min(0.6, 0.8) = 0.6 → 900×1200 shown, 200 px bars at top and bottom
    close(
      viewRectToImageRect(
        { x: 0, y: 0, width: 1, height: 1 },
        view,
        image,
        'contain',
      ),
      { x: 0, y: 0, width: 1, height: 1 },
    );
    close(
      viewRectToImageRect(
        { x: 0.5, y: 0.5, width: 0.25, height: 0.25 },
        view,
        image,
        'contain',
      ),
      { x: 0.5, y: 600 / 1200, width: 0.25, height: 400 / 1200 },
    );
  });

  it('round-trips inside the visible area', () => {
    for (const mode of ['cover', 'contain'] as const) {
      const rect = { x: 0.2, y: 0.3, width: 0.4, height: 0.2 };
      const there = viewRectToImageRect(rect, view, image, mode);
      close(imageRectToViewRect(there, view, image, mode), rect);
    }
  });
});
