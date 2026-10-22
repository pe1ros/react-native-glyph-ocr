import { useState } from 'react';
import {
  Pressable,
  type StyleProp,
  StyleSheet,
  View,
  type ViewStyle,
} from 'react-native';

import type {
  OcrBlock,
  OcrElement,
  OcrImageSize,
  OcrLine,
  OcrPoint,
  OcrResult,
  ViewResizeMode,
} from './specs/Ocr.nitro';

export type OcrNode = OcrBlock | OcrLine | OcrElement;
export type OverlayLevel = 'blocks' | 'lines' | 'elements';

export interface ViewBox {
  /** Center in view points. */
  cx: number;
  cy: number;
  /** Along and across the text, in view points. */
  width: number;
  height: number;
  /** Degrees, clockwise. */
  angle: number;
}

/** A normalized point of the image → view points, for an image shown with `resizeMode`. */
export function imagePointToViewPoint(
  point: OcrPoint,
  view: { width: number; height: number },
  image: OcrImageSize,
  resizeMode: ViewResizeMode = 'contain',
): OcrPoint {
  const pick = resizeMode === 'cover' ? Math.max : Math.min;
  const scale = pick(view.width / image.width, view.height / image.height);
  return {
    x: point.x * image.width * scale + (view.width - image.width * scale) / 2,
    y:
      point.y * image.height * scale + (view.height - image.height * scale) / 2,
  };
}

/** The rotated rectangle a node covers on screen, from its corner points (TL, TR, BR, BL). */
export function nodeToViewBox(
  node: Pick<OcrNode, 'cornerPoints'>,
  view: { width: number; height: number },
  image: OcrImageSize,
  resizeMode: ViewResizeMode = 'contain',
): ViewBox | undefined {
  if (node.cornerPoints.length !== 4) {
    return undefined;
  }
  const [tl, tr, br, bl] = node.cornerPoints.map(p =>
    imagePointToViewPoint(p, view, image, resizeMode),
  ) as [OcrPoint, OcrPoint, OcrPoint, OcrPoint];
  const top = Math.hypot(tr.x - tl.x, tr.y - tl.y);
  const bottom = Math.hypot(br.x - bl.x, br.y - bl.y);
  const left = Math.hypot(bl.x - tl.x, bl.y - tl.y);
  const right = Math.hypot(br.x - tr.x, br.y - tr.y);
  return {
    cx: (tl.x + tr.x + br.x + bl.x) / 4,
    cy: (tl.y + tr.y + br.y + bl.y) / 4,
    width: (top + bottom) / 2,
    height: (left + right) / 2,
    angle:
      (Math.atan2(tr.y - tl.y + (br.y - bl.y), tr.x - tl.x + (br.x - bl.x)) *
        180) /
      Math.PI,
  };
}

/** The nodes of one level, in reading order. */
export function nodesOf(result: OcrResult, level: OverlayLevel): OcrNode[] {
  if (level === 'blocks') {
    return result.blocks;
  }
  const lines = result.blocks.flatMap(b => b.lines);
  return level === 'lines' ? lines : lines.flatMap(l => l.elements);
}

export interface OcrOverlayProps {
  result: OcrResult;
  /** How the image or camera preview under the overlay is shown. Default `contain`. */
  resizeMode?: ViewResizeMode;
  /** Default `lines`. `elements` needs `output: 'elements'` (the default). */
  level?: OverlayLevel;
  /** Called with the tapped node; the overlay then highlights it. Without it boxes ignore touches. */
  onPress?: (node: OcrNode, index: number) => void;
  /** Index of the highlighted node; uncontrolled (the last tapped one) when undefined. */
  selected?: number;
  boxStyle?: StyleProp<ViewStyle>;
  selectedBoxStyle?: StyleProp<ViewStyle>;
  style?: StyleProp<ViewStyle>;
}

/**
 * Boxes of an `OcrResult` drawn over the image it came from. Put it in the same parent as the
 * image, with the same size: it fills its parent and maps the boxes with `resizeMode`, rotated
 * along the text.
 */
export function OcrOverlay({
  result,
  resizeMode = 'contain',
  level = 'lines',
  onPress,
  selected,
  boxStyle,
  selectedBoxStyle,
  style,
}: OcrOverlayProps) {
  const [view, setView] = useState<{ width: number; height: number }>();
  const [tapped, setTapped] = useState<number>();
  const highlighted = selected ?? tapped;
  const nodes = nodesOf(result, level);
  return (
    <View
      pointerEvents={onPress ? 'box-none' : 'none'}
      style={[StyleSheet.absoluteFill, style]}
      onLayout={e => setView(e.nativeEvent.layout)}
    >
      {view
        ? nodes.map((node, i) => {
            const box = nodeToViewBox(node, view, result.image, resizeMode);
            if (box == null) {
              return null;
            }
            const frame: ViewStyle = {
              position: 'absolute',
              left: box.cx - box.width / 2,
              top: box.cy - box.height / 2,
              width: box.width,
              height: box.height,
              transform: [{ rotate: `${box.angle}deg` }],
            };
            const look = [
              styles.box,
              boxStyle,
              i === highlighted && [styles.selected, selectedBoxStyle],
            ];
            return onPress ? (
              <Pressable
                key={i}
                accessibilityRole="button"
                accessibilityLabel={node.text}
                onPress={() => {
                  setTapped(i);
                  onPress(node, i);
                }}
                style={[frame, look]}
              />
            ) : (
              <View key={i} style={[frame, look]} />
            );
          })
        : null}
    </View>
  );
}

const styles = StyleSheet.create({
  box: {
    borderWidth: 1.5,
    borderColor: '#1e88e5',
    backgroundColor: 'rgba(30,136,229,0.08)',
    borderRadius: 2,
  },
  selected: {
    borderColor: '#f9a825',
    backgroundColor: 'rgba(249,168,37,0.25)',
  },
});
