// Edit model and the edit-file format. Port of Annotation.swift; the JSON must stay readable by the
// macOS app and vice versa (docs/DEVELOPMENT.md).
import type { AnnotationJSON, EditFileJSON } from '../types';

export interface Point {
  x: number;
  y: number;
}

/** Always standardized (non-negative width and height) once it leaves the model. */
export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface Size {
  w: number;
  h: number;
}

// ---------------------------------------------------------------- colour

export interface RGBA {
  r: number;
  g: number;
  b: number;
  a: number;
}

/** `#RRGGBB` or `#RRGGBBAA` to components in 0..1. */
export function parseHex(hex: string): RGBA | null {
  let s = hex.trim();
  if (s.startsWith('#')) s = s.slice(1);
  if ((s.length !== 6 && s.length !== 8) || !/^[0-9a-fA-F]+$/.test(s)) return null;
  const byte = (i: number) => parseInt(s.slice(i, i + 2), 16) / 255;
  return { r: byte(0), g: byte(2), b: byte(4), a: s.length === 8 ? byte(6) : 1 };
}

const hex2 = (v: number) =>
  Math.round(Math.min(Math.max(v, 0), 1) * 255)
    .toString(16)
    .toUpperCase()
    .padStart(2, '0');

/** Same rule as Swift: alpha is only written when it is below 1. */
export function formatHex(c: RGBA): string {
  const base = `#${hex2(c.r)}${hex2(c.g)}${hex2(c.b)}`;
  return c.a < 1 ? base + hex2(c.a) : base;
}

/** Canonical form of a colour string, or null when it does not parse. */
export function normalizeHex(hex: string): string | null {
  const c = parseHex(hex);
  return c ? formatHex(c) : null;
}

/** Whether dark text reads better on top of this colour. */
export function isLight(hex: string): boolean {
  const c = parseHex(hex) ?? { r: 0, g: 0, b: 0, a: 1 };
  return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.66;
}

export function withAlpha(hex: string, alpha: number): string {
  const c = parseHex(hex) ?? { r: 0, g: 0, b: 0, a: 1 };
  return formatHex({ ...c, a: alpha });
}

export const PALETTE: { name: string; color: string }[] = [
  { name: 'Red', color: '#E5342E' },
  { name: 'Orange', color: '#F27A1A' },
  { name: 'Yellow', color: '#F5C518' },
  { name: 'Green', color: '#2E9E5B' },
  { name: 'Blue', color: '#2F6FEB' },
  { name: 'Ink', color: '#16171A' },
  { name: 'White', color: '#FFFFFF' },
];

export const DEFAULT_COLOR = '#E5342E';

// ---------------------------------------------------------------- annotations

export const ANNOTATION_TYPES = [
  'rectangle',
  'ellipse',
  'line',
  'arrow',
  'pen',
  'highlighter',
  'text',
  'step',
  'redaction',
] as const;
export type AnnotationType = (typeof ANNOTATION_TYPES)[number];

export const REDACTIONS = ['pixelate', 'blur', 'blackout'] as const;
export type Redaction = (typeof REDACTIONS)[number];

export const REDACTION_TITLES: Record<Redaction, string> = {
  pixelate: 'Pixelate',
  blur: 'Blur',
  blackout: 'Black out',
};

/** Free rectangle with eight resize handles. */
export const isBoxed = (t: AnnotationType) => t === 'rectangle' || t === 'ellipse' || t === 'redaction';
/** Two endpoints in `points`. */
export const isSegment = (t: AnnotationType) => t === 'line' || t === 'arrow';
export const isFreehand = (t: AnnotationType) => t === 'pen' || t === 'highlighter';
export const usesStroke = (t: AnnotationType) => t !== 'text' && t !== 'step' && t !== 'redaction';
export const usesTextSize = (t: AnnotationType) => t === 'text' || t === 'step';
export const canFill = (t: AnnotationType) => t === 'rectangle' || t === 'ellipse';

export const TYPE_NAMES: Record<AnnotationType, string> = {
  rectangle: 'Rectangle',
  ellipse: 'Ellipse',
  line: 'Line',
  arrow: 'Arrow',
  pen: 'Pen',
  highlighter: 'Highlighter',
  text: 'Text',
  step: 'Step number',
  redaction: 'Redaction',
};

/** One edit on top of a capture, in image points (origin top-left). */
export interface Annotation {
  id: string;
  type: AnnotationType;
  frame: Rect;
  points: Point[];
  color: string;
  stroke: number;
  filled: boolean;
  text: string;
  textSize: number;
  step: number;
  redaction: Redaction;
}

/** Swift's UUID().uuidString is upper case. */
export function newId(): string {
  const c = globalThis.crypto;
  if (c && 'randomUUID' in c) return c.randomUUID().toUpperCase();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    .replace(/[xy]/g, (ch) => {
      const r = (Math.random() * 16) | 0;
      return (ch === 'x' ? r : (r & 0x3) | 0x8).toString(16);
    })
    .toUpperCase();
}

export function makeAnnotation(type: AnnotationType, init: Partial<Annotation> = {}): Annotation {
  return {
    id: newId(),
    type,
    frame: { x: 0, y: 0, w: 0, h: 0 },
    points: [],
    color: DEFAULT_COLOR,
    stroke: 4,
    filled: false,
    text: '',
    textSize: 28,
    step: 1,
    redaction: 'pixelate',
    ...init,
  };
}

/** Copy deep enough that mutating the copy never touches the original (undo history shares objects). */
export function cloneAnnotation(a: Annotation): Annotation {
  return { ...a, frame: { ...a.frame }, points: a.points.map((p) => ({ ...p })) };
}

export function standardize(r: Rect): Rect {
  return {
    x: r.w < 0 ? r.x + r.w : r.x,
    y: r.h < 0 ? r.y + r.h : r.y,
    w: Math.abs(r.w),
    h: Math.abs(r.h),
  };
}

/** Bounds for hit testing, selection and invalidation. */
export function annotationBounds(a: Annotation): Rect {
  if (!(isSegment(a.type) || isFreehand(a.type)) || a.points.length === 0) return standardize(a.frame);
  let minX = a.points[0].x,
    minY = a.points[0].y,
    maxX = minX,
    maxY = minY;
  for (const p of a.points) {
    minX = Math.min(minX, p.x);
    minY = Math.min(minY, p.y);
    maxX = Math.max(maxX, p.x);
    maxY = Math.max(maxY, p.y);
  }
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
}

export function offsetAnnotation(a: Annotation, dx: number, dy: number): Annotation {
  return {
    ...a,
    frame: { ...a.frame, x: a.frame.x + dx, y: a.frame.y + dy },
    points: a.points.map((p) => ({ x: p.x + dx, y: p.y + dy })),
  };
}

// ---------------------------------------------------------------- backdrop

export const BACKDROP_PRESETS = ['snow', 'slate', 'mist', 'sky', 'sage', 'dusk'] as const;
export type BackdropPreset = (typeof BACKDROP_PRESETS)[number];

/** Flat or barely two-tone, never loud. Top colour first. */
export const PRESET_COLORS: Record<BackdropPreset, [string, string]> = {
  snow: ['#F5F6F7', '#ECEEF0'],
  slate: ['#30343A', '#272A2F'],
  mist: ['#E3E8ED', '#CDD5DD'],
  sky: ['#D9E7F4', '#BCD3E9'],
  sage: ['#DCE4DA', '#C3D1C1'],
  dusk: ['#3A4250', '#1F242C'],
};

export const presetTitle = (p: BackdropPreset) => p[0].toUpperCase() + p.slice(1);

export type BackdropFill = { kind: 'preset'; preset: BackdropPreset } | { kind: 'color'; color: string };

export interface Backdrop {
  enabled: boolean;
  fill: BackdropFill;
  padding: number;
  radius: number;
  shadow: boolean;
}

export function defaultBackdrop(): Backdrop {
  return { enabled: false, fill: { kind: 'preset', preset: 'mist' }, padding: 48, radius: 10, shadow: true };
}

export function sameFill(a: BackdropFill, b: BackdropFill): boolean {
  return a.kind === 'preset' && b.kind === 'preset'
    ? a.preset === b.preset
    : a.kind === 'color' && b.kind === 'color' && a.color === b.color;
}

// ---------------------------------------------------------------- edit file

export const CURRENT_FORMAT = 1;

export interface EditFile {
  format: number;
  scale: number;
  annotations: Annotation[];
  crop: Rect | null;
  backdrop: Backdrop;
}

export function hasEdits(e: Pick<EditFile, 'annotations' | 'crop' | 'backdrop'>): boolean {
  return e.annotations.length > 0 || e.crop !== null || e.backdrop.enabled;
}

const num = (v: unknown, fallback: number) => (typeof v === 'number' && Number.isFinite(v) ? v : fallback);
const rectFromArray = (f: unknown): Rect | null =>
  Array.isArray(f) && f.length === 4 && f.every((v) => typeof v === 'number')
    ? standardize({ x: f[0], y: f[1], w: f[2], h: f[3] })
    : null;

export function decodeAnnotation(j: AnnotationJSON): Annotation | null {
  if (!(ANNOTATION_TYPES as readonly string[]).includes(j.type)) return null;
  const type = j.type as AnnotationType;
  const points = Array.isArray(j.points)
    ? j.points.filter((p) => Array.isArray(p) && p.length === 2).map((p) => ({ x: Number(p[0]), y: Number(p[1]) }))
    : [];
  return {
    id: typeof j.id === 'string' && j.id ? j.id : newId(),
    type,
    frame: rectFromArray(j.frame) ?? { x: 0, y: 0, w: 0, h: 0 },
    points,
    color: (typeof j.color === 'string' && normalizeHex(j.color)) || DEFAULT_COLOR,
    stroke: num(j.stroke, 4),
    filled: j.filled === true,
    text: typeof j.text === 'string' ? j.text : '',
    textSize: num(j.text_size, 28),
    step: Math.round(num(j.step, 1)),
    redaction: (REDACTIONS as readonly string[]).includes(j.redaction ?? '') ? (j.redaction as Redaction) : 'pixelate',
  };
}

/** Compact encoding: only the fields that matter for the type, in Swift's key order. */
export function encodeAnnotation(a: Annotation): AnnotationJSON {
  const out: AnnotationJSON = { id: a.id, type: a.type, color: a.color };
  if (isSegment(a.type) || isFreehand(a.type)) {
    out.points = a.points.map((p) => [p.x, p.y]);
  } else {
    const f = standardize(a.frame);
    out.frame = [f.x, f.y, f.w, f.h];
  }
  if (usesStroke(a.type)) out.stroke = a.stroke;
  if (canFill(a.type) && a.filled) out.filled = true;
  if (a.type === 'text') out.text = a.text;
  if (usesTextSize(a.type)) out.text_size = a.textSize;
  if (a.type === 'step') out.step = a.step;
  if (a.type === 'redaction') out.redaction = a.redaction;
  return out;
}

export function decodeBackdrop(j: EditFileJSON['backdrop']): Backdrop {
  const d = defaultBackdrop();
  if (!j) return d;
  const color = typeof j.color === 'string' ? normalizeHex(j.color) : null;
  const preset = (BACKDROP_PRESETS as readonly string[]).includes(j.preset ?? '') ? (j.preset as BackdropPreset) : 'mist';
  return {
    enabled: j.enabled === true,
    fill: color ? { kind: 'color', color } : { kind: 'preset', preset },
    padding: num(j.padding, d.padding),
    radius: num(j.radius, d.radius),
    shadow: typeof j.shadow === 'boolean' ? j.shadow : d.shadow,
  };
}

export function encodeBackdrop(b: Backdrop): NonNullable<EditFileJSON['backdrop']> {
  const out: NonNullable<EditFileJSON['backdrop']> = { enabled: b.enabled };
  if (b.fill.kind === 'preset') out.preset = b.fill.preset;
  else out.color = b.fill.color;
  out.padding = b.padding;
  out.radius = b.radius;
  out.shadow = b.shadow;
  return out;
}

/** Lenient like the Swift decoder: missing keys take their defaults, unknown annotation types are skipped. */
export function decodeEditFile(j: EditFileJSON): EditFile {
  return {
    format: Math.round(num(j.format, 1)),
    scale: num(j.scale, 1),
    annotations: (Array.isArray(j.annotations) ? j.annotations : [])
      .map(decodeAnnotation)
      .filter((a): a is Annotation => a !== null),
    crop: rectFromArray(j.crop),
    backdrop: decodeBackdrop(j.backdrop),
  };
}

/** Key order follows EditFile.encode in Swift: format, scale, annotations, crop (only when set), backdrop. */
export function encodeEditFile(e: EditFile): EditFileJSON {
  const out: EditFileJSON = { format: e.format, scale: e.scale, annotations: e.annotations.map(encodeAnnotation) };
  if (e.crop) out.crop = [e.crop.x, e.crop.y, e.crop.w, e.crop.h];
  out.backdrop = encodeBackdrop(e.backdrop);
  return out;
}

// ---------------------------------------------------------------- presets

export const STROKE_PRESETS = [
  { title: 'S', value: 2 },
  { title: 'M', value: 4 },
  { title: 'L', value: 8 },
  { title: 'XL', value: 14 },
];

export const TEXT_SIZE_PRESETS = [
  { title: 'S', value: 18 },
  { title: 'M', value: 28 },
  { title: 'L', value: 44 },
];

export function nearestPreset(presets: { value: number }[], v: number): number {
  return presets.reduce((best, p) => (Math.abs(p.value - v) < Math.abs(best - v) ? p.value : best), presets[0].value);
}
