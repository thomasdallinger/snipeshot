import { describe, expect, it } from 'vitest';
import type { EditFileJSON } from '../types';
import {
  decodeEditFile,
  encodeAnnotation,
  encodeEditFile,
  formatHex,
  hasEdits,
  isLight,
  makeAnnotation,
  normalizeHex,
  parseHex,
} from './model';

// The example from docs/DEVELOPMENT.md, exactly as the macOS app writes it.
const EXAMPLE = `{
  "format": 1,
  "scale": 2,
  "crop": [20, 20, 200, 150],
  "backdrop": { "enabled": true, "preset": "mist", "padding": 48, "radius": 10, "shadow": true },
  "annotations": [
    { "id": "…", "type": "arrow", "color": "#E5342E", "points": [[200, 200], [300, 250]], "stroke": 4 },
    { "id": "…", "type": "text", "color": "#E5342E", "frame": [40, 60, 120, 34], "text": "Check this", "text_size": 28 }
  ]
}`;

describe('edit file', () => {
  it('round-trips the documented example', () => {
    const json = JSON.parse(EXAMPLE) as EditFileJSON;
    const file = decodeEditFile(json);
    expect(file.scale).toBe(2);
    expect(file.crop).toEqual({ x: 20, y: 20, w: 200, h: 150 });
    expect(file.backdrop).toEqual({ enabled: true, fill: { kind: 'preset', preset: 'mist' }, padding: 48, radius: 10, shadow: true });
    expect(file.annotations[0].points).toEqual([
      { x: 200, y: 200 },
      { x: 300, y: 250 },
    ]);
    expect(file.annotations[1].textSize).toBe(28);
    expect(JSON.parse(JSON.stringify(encodeEditFile(file)))).toEqual(json);
  });

  it('writes keys in the Swift order and omits crop when unset', () => {
    const file = decodeEditFile(JSON.parse(EXAMPLE));
    expect(Object.keys(encodeEditFile(file))).toEqual(['format', 'scale', 'annotations', 'crop', 'backdrop']);
    expect(Object.keys(encodeEditFile({ ...file, crop: null }))).toEqual(['format', 'scale', 'annotations', 'backdrop']);
    expect(Object.keys(encodeAnnotation(file.annotations[1]))).toEqual(['id', 'type', 'color', 'frame', 'text', 'text_size']);
  });

  it('encodes only the fields each type uses', () => {
    const step = encodeAnnotation(makeAnnotation('step', { id: 'S', frame: { x: 1, y: 2, w: 28, h: 28 }, step: 3 }));
    expect(step).toEqual({ id: 'S', type: 'step', color: '#E5342E', frame: [1, 2, 28, 28], text_size: 28, step: 3 });

    const red = encodeAnnotation(makeAnnotation('redaction', { id: 'R', frame: { x: 0, y: 0, w: 5, h: 6 }, redaction: 'blur' }));
    expect(red).toEqual({ id: 'R', type: 'redaction', color: '#E5342E', frame: [0, 0, 5, 6], redaction: 'blur' });

    const pen = encodeAnnotation(makeAnnotation('pen', { id: 'P', points: [{ x: 1, y: 1 }], stroke: 8 }));
    expect(pen).toEqual({ id: 'P', type: 'pen', color: '#E5342E', points: [[1, 1]], stroke: 8 });

    const rect = makeAnnotation('rectangle', { id: 'Q', frame: { x: 0, y: 0, w: 4, h: 4 } });
    expect(encodeAnnotation(rect)).not.toHaveProperty('filled');
    expect(encodeAnnotation({ ...rect, filled: true }).filled).toBe(true);
    // Fill is meaningless on a line, so it is never written.
    expect(encodeAnnotation(makeAnnotation('line', { filled: true, points: [] }))).not.toHaveProperty('filled');
  });

  it('standardizes negative frames like CGRect.minX', () => {
    const a = makeAnnotation('ellipse', { frame: { x: 50, y: 40, w: -20, h: -10 } });
    expect(encodeAnnotation(a).frame).toEqual([30, 30, 20, 10]);
  });

  it('writes a custom backdrop colour instead of a preset', () => {
    const file = decodeEditFile({ backdrop: { enabled: true, color: '#112233' } });
    expect(file.backdrop.fill).toEqual({ kind: 'color', color: '#112233' });
    const out = encodeEditFile(file).backdrop!;
    expect(out.color).toBe('#112233');
    expect(out).not.toHaveProperty('preset');
  });

  it('decodes leniently with defaults and skips unknown types', () => {
    const file = decodeEditFile({
      annotations: [{ type: 'sparkle' }, { type: 'rectangle' }] as EditFileJSON['annotations'],
    });
    expect(file.format).toBe(1);
    expect(file.scale).toBe(1);
    expect(file.crop).toBeNull();
    expect(file.backdrop.enabled).toBe(false);
    expect(file.annotations).toHaveLength(1);
    const a = file.annotations[0];
    expect(a.color).toBe('#E5342E');
    expect(a.stroke).toBe(4);
    expect(a.id).toMatch(/^[0-9A-F-]{36}$/);
  });

  it('knows when there is nothing to keep', () => {
    const empty = decodeEditFile({});
    expect(hasEdits(empty)).toBe(false);
    expect(hasEdits({ ...empty, crop: { x: 0, y: 0, w: 1, h: 1 } })).toBe(true);
    expect(hasEdits({ ...empty, backdrop: { ...empty.backdrop, enabled: true } })).toBe(true);
  });
});

describe('colours', () => {
  it('parses #RRGGBB and #RRGGBBAA', () => {
    expect(parseHex('#FF0000')).toEqual({ r: 1, g: 0, b: 0, a: 1 });
    expect(parseHex('00FF0080')!.a).toBeCloseTo(128 / 255);
    expect(parseHex('#F00')).toBeNull();
    expect(parseHex('#GG0000')).toBeNull();
  });

  it('writes alpha only below 1, upper case', () => {
    expect(normalizeHex('#e5342e')).toBe('#E5342E');
    expect(normalizeHex('#E5342EFF')).toBe('#E5342E');
    expect(normalizeHex('#E5342E80')).toBe('#E5342E80');
    expect(formatHex({ r: 1, g: 1, b: 1, a: 0.5 })).toBe('#FFFFFF80');
  });

  it('picks dark text on light colours', () => {
    expect(isLight('#FFFFFF')).toBe(true);
    expect(isLight('#F5C518')).toBe(true);
    expect(isLight('#E5342E')).toBe(false);
    expect(isLight('#16171A')).toBe(false);
  });
});
