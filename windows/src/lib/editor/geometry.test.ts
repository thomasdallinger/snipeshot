import { describe, expect, it } from 'vitest';
import {
  canvasSize,
  canvasToDoc,
  docToCanvas,
  fitZoom,
  hitTest,
  imageFrame,
  integral,
  isDegenerate,
  makeLayout,
  outputPixelSize,
  rectFrom,
  resizeRect,
  snap45,
} from './geometry';
import { defaultBackdrop, makeAnnotation } from './model';

const size = { w: 400, h: 300 };

describe('canvas layout', () => {
  it('is the whole image without crop or backdrop', () => {
    const l = makeLayout(size, null, defaultBackdrop());
    expect(l.contentRect).toEqual({ x: 0, y: 0, w: 400, h: 300 });
    expect(l.padding).toBe(0);
    expect(canvasSize(l)).toEqual(size);
  });

  it('rounds the crop outwards and keeps it inside the image', () => {
    const l = makeLayout(size, { x: 10.4, y: -5, w: 100.2, h: 400 }, defaultBackdrop());
    expect(l.contentRect).toEqual({ x: 10, y: 0, w: 101, h: 300 });
    expect(integral({ x: 1.5, y: 2.5, w: 1, h: 1 })).toEqual({ x: 1, y: 2, w: 2, h: 2 });
  });

  it('adds backdrop padding around the content', () => {
    const bd = { ...defaultBackdrop(), enabled: true, padding: 48 };
    const l = makeLayout(size, { x: 20, y: 20, w: 200, h: 150 }, bd);
    expect(canvasSize(l)).toEqual({ w: 296, h: 246 });
    expect(imageFrame(l)).toEqual({ x: 48, y: 48, w: 200, h: 150 });
    const p = { x: 25, y: 30 };
    expect(docToCanvas(l, p)).toEqual({ x: 53, y: 58 });
    expect(canvasToDoc(l, docToCanvas(l, p))).toEqual(p);
    // Exported at full pixel size.
    expect(outputPixelSize(l, 2)).toEqual({ w: 592, h: 492 });
  });

  it('shows the full image without backdrop while cropping', () => {
    const bd = { ...defaultBackdrop(), enabled: true };
    const l = makeLayout(size, { x: 20, y: 20, w: 200, h: 150 }, bd, true);
    expect(l.padding).toBe(0);
    expect(l.backdrop).toBeNull();
    expect(canvasSize(l)).toEqual(size);
  });

  it('fits with 32 px of room and never zooms past 100 %', () => {
    expect(fitZoom({ w: 400, h: 300 }, { w: 2000, h: 2000 })).toBe(1);
    expect(fitZoom({ w: 1000, h: 500 }, { w: 564, h: 1000 })).toBeCloseTo(0.5);
    expect(fitZoom({ w: 100000, h: 100000 }, { w: 100, h: 100 })).toBe(0.05);
  });
});

describe('shape math', () => {
  it('draws rects from any corner, square with Shift', () => {
    expect(rectFrom({ x: 50, y: 50 }, { x: 10, y: 30 }, false)).toEqual({ x: 10, y: 30, w: 40, h: 20 });
    expect(rectFrom({ x: 0, y: 0 }, { x: 30, y: -10 }, true)).toEqual({ x: 0, y: -30, w: 30, h: 30 });
  });

  it('snaps lines to 45°', () => {
    const p = snap45({ x: 0, y: 0 }, { x: 10, y: 1 });
    expect(p.x).toBeCloseTo(Math.hypot(10, 1));
    expect(p.y).toBeCloseTo(0);
    const d = snap45({ x: 0, y: 0 }, { x: 10, y: 9 });
    expect(d.x).toBeCloseTo(d.y);
  });

  it('resizes from a handle and flips past the opposite edge', () => {
    const r = { x: 10, y: 10, w: 100, h: 50 };
    expect(resizeRect(r, 'bottomRight', { x: 60, y: 30 })).toEqual({ x: 10, y: 10, w: 50, h: 20 });
    expect(resizeRect(r, 'left', { x: 150, y: 0 })).toEqual({ x: 110, y: 10, w: 40, h: 50 });
    expect(resizeRect(r, 'top', { x: 0, y: 0 })).toEqual({ x: 10, y: 0, w: 100, h: 60 });
  });

  it('hits outlines, not the inside, of unfilled shapes', () => {
    const outline = makeAnnotation('rectangle', { id: 'o', frame: { x: 0, y: 0, w: 100, h: 100 }, stroke: 4 });
    expect(hitTest([outline], { x: 2, y: 50 }, 6)?.id).toBe('o');
    expect(hitTest([outline], { x: 50, y: 50 }, 6)).toBeNull();
    const filled = { ...outline, id: 'f', filled: true };
    expect(hitTest([filled], { x: 50, y: 50 }, 6)?.id).toBe('f');
  });

  it('prefers the topmost annotation and follows lines', () => {
    const a = makeAnnotation('arrow', { id: 'a', points: [{ x: 0, y: 0 }, { x: 100, y: 0 }], stroke: 4 });
    const t = makeAnnotation('text', { id: 't', frame: { x: 40, y: -10, w: 40, h: 20 } });
    expect(hitTest([a, t], { x: 50, y: 0 }, 6)?.id).toBe('t');
    expect(hitTest([a, t], { x: 20, y: 5 }, 6)?.id).toBe('a');
    expect(hitTest([a, t], { x: 20, y: 30 }, 6)).toBeNull();
  });

  it('drops tiny shapes but keeps any freehand stroke', () => {
    expect(isDegenerate(makeAnnotation('rectangle', { frame: { x: 0, y: 0, w: 2, h: 50 } }))).toBe(true);
    expect(isDegenerate(makeAnnotation('line', { points: [{ x: 0, y: 0 }, { x: 1, y: 1 }] }))).toBe(true);
    expect(isDegenerate(makeAnnotation('pen', { points: [{ x: 0, y: 0 }] }))).toBe(false);
  });
});
