// Canvas layout and the pure geometry behind the canvas tools (Renderer.swift, CanvasView.swift).
import {
  annotationBounds,
  standardize,
  type Annotation,
  type Backdrop,
  type Point,
  type Rect,
  type Size,
} from './model';

/** Where the capture sits inside the rendered canvas (crop plus backdrop padding). */
export interface CanvasLayout {
  /** Visible part of the image, in document points. */
  contentRect: Rect;
  /** Backdrop padding around the content, 0 when the backdrop is off. */
  padding: number;
  backdrop: Backdrop | null;
}

export function makeLayout(pointSize: Size, crop: Rect | null, backdrop: Backdrop, showFullImage = false): CanvasLayout {
  const full = { x: 0, y: 0, w: pointSize.w, h: pointSize.h };
  if (showFullImage) return { contentRect: full, padding: 0, backdrop: null };
  const content = intersect(integral(crop ?? full), full);
  const bd = backdrop.enabled ? backdrop : null;
  return { contentRect: content, padding: bd?.padding ?? 0, backdrop: bd };
}

export const canvasSize = (l: CanvasLayout): Size => ({
  w: l.contentRect.w + l.padding * 2,
  h: l.contentRect.h + l.padding * 2,
});

/** Content frame in canvas coordinates. */
export const imageFrame = (l: CanvasLayout): Rect => ({
  x: l.padding,
  y: l.padding,
  w: l.contentRect.w,
  h: l.contentRect.h,
});

export const docToCanvas = (l: CanvasLayout, p: Point): Point => ({
  x: p.x - l.contentRect.x + l.padding,
  y: p.y - l.contentRect.y + l.padding,
});

export const canvasToDoc = (l: CanvasLayout, p: Point): Point => ({
  x: p.x + l.contentRect.x - l.padding,
  y: p.y + l.contentRect.y - l.padding,
});

export const docRectToCanvas = (l: CanvasLayout, r: Rect): Rect => ({
  ...r,
  x: r.x + l.padding - l.contentRect.x,
  y: r.y + l.padding - l.contentRect.y,
});

/** Pixel size of the exported image. */
export function outputPixelSize(l: CanvasLayout, scale: number): Size {
  const s = canvasSize(l);
  return { w: Math.round(s.w * scale), h: Math.round(s.h * scale) };
}

// ---------------------------------------------------------------- rects

/** CGRect.integral: smallest integer rect that contains `r`. */
export function integral(r: Rect): Rect {
  const s = standardize(r);
  const x = Math.floor(s.x),
    y = Math.floor(s.y);
  return { x, y, w: Math.ceil(s.x + s.w) - x, h: Math.ceil(s.y + s.h) - y };
}

export function intersect(a: Rect, b: Rect): Rect {
  const x = Math.max(a.x, b.x),
    y = Math.max(a.y, b.y);
  const w = Math.min(a.x + a.w, b.x + b.w) - x,
    h = Math.min(a.y + a.h, b.y + b.h) - y;
  return w <= 0 || h <= 0 ? { x: 0, y: 0, w: 0, h: 0 } : { x, y, w, h };
}

export const inset = (r: Rect, dx: number, dy = dx): Rect => ({ x: r.x + dx, y: r.y + dy, w: r.w - 2 * dx, h: r.h - 2 * dy });
export const contains = (r: Rect, p: Point) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
export const rectEquals = (a: Rect | null, b: Rect | null) =>
  a === b || (!!a && !!b && a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h);
export const isEmptyRect = (r: Rect) => r.w <= 0 || r.h <= 0;

export function rectFrom(a: Point, b: Point, square: boolean): Rect {
  let w = b.x - a.x,
    h = b.y - a.y;
  if (square) {
    const side = Math.max(Math.abs(w), Math.abs(h));
    w = side * (w < 0 ? -1 : 1);
    h = side * (h < 0 ? -1 : 1);
  }
  return standardize({ x: a.x, y: a.y, w, h });
}

/** Snaps the direction from `a` to `b` to the nearest 45°. */
export function snap45(a: Point, b: Point): Point {
  const dx = b.x - a.x,
    dy = b.y - a.y;
  const angle = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
  const len = Math.hypot(dx, dy);
  return { x: a.x + Math.cos(angle) * len, y: a.y + Math.sin(angle) * len };
}

export type Handle =
  | 'topLeft'
  | 'top'
  | 'topRight'
  | 'left'
  | 'right'
  | 'bottomLeft'
  | 'bottom'
  | 'bottomRight'
  | 'lineStart'
  | 'lineEnd';

export function rectHandles(r: Rect): [Handle, Point][] {
  const midX = r.x + r.w / 2,
    midY = r.y + r.h / 2,
    maxX = r.x + r.w,
    maxY = r.y + r.h;
  return [
    ['topLeft', { x: r.x, y: r.y }],
    ['top', { x: midX, y: r.y }],
    ['topRight', { x: maxX, y: r.y }],
    ['left', { x: r.x, y: midY }],
    ['right', { x: maxX, y: midY }],
    ['bottomLeft', { x: r.x, y: maxY }],
    ['bottom', { x: midX, y: maxY }],
    ['bottomRight', { x: maxX, y: maxY }],
  ];
}

/** Moves the edges a handle controls to `p`; flips cleanly when dragged past the opposite edge. */
export function resizeRect(r: Rect, handle: Handle, p: Point): Rect {
  let minX = r.x,
    minY = r.y,
    maxX = r.x + r.w,
    maxY = r.y + r.h;
  switch (handle) {
    case 'topLeft':
      minX = p.x;
      minY = p.y;
      break;
    case 'top':
      minY = p.y;
      break;
    case 'topRight':
      maxX = p.x;
      minY = p.y;
      break;
    case 'left':
      minX = p.x;
      break;
    case 'right':
      maxX = p.x;
      break;
    case 'bottomLeft':
      minX = p.x;
      maxY = p.y;
      break;
    case 'bottom':
      maxY = p.y;
      break;
    case 'bottomRight':
      maxX = p.x;
      maxY = p.y;
      break;
  }
  return { x: Math.min(minX, maxX), y: Math.min(minY, maxY), w: Math.abs(maxX - minX), h: Math.abs(maxY - minY) };
}

export function distanceToSegment(p: Point, a: Point, b: Point): number {
  const dx = b.x - a.x,
    dy = b.y - a.y;
  const len2 = dx * dx + dy * dy;
  if (len2 <= 0) return Math.hypot(p.x - a.x, p.y - a.y);
  const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2));
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

/** Topmost annotation under a document point. `tol` is the screen tolerance in document units. */
export function hitTest(annotations: Annotation[], p: Point, tol: number): Annotation | null {
  for (let i = annotations.length - 1; i >= 0; i--) {
    const a = annotations[i];
    switch (a.type) {
      case 'line':
      case 'arrow':
      case 'pen':
      case 'highlighter': {
        const reach = Math.max(a.stroke * (a.type === 'highlighter' ? 1.6 : 0.5), 0) + tol;
        if (a.points.length === 1 && Math.hypot(a.points[0].x - p.x, a.points[0].y - p.y) < reach) return a;
        for (let j = 0; j < a.points.length - 1; j++) {
          if (distanceToSegment(p, a.points[j], a.points[j + 1]) < reach) return a;
        }
        break;
      }
      case 'rectangle':
      case 'ellipse': {
        const r = standardize(a.frame);
        const outer = inset(r, -tol);
        if (a.filled) {
          if (contains(outer, p)) return a;
        } else {
          const inner = inset(r, a.stroke + tol);
          if (contains(outer, p) && (isEmptyRect(inner) || !contains(inner, p))) return a;
        }
        break;
      }
      default:
        if (contains(inset(annotationBounds(a), -tol), p)) return a;
    }
  }
  return null;
}

/** Shapes too small to mean anything are dropped at the end of a drag. */
export function isDegenerate(a: Annotation): boolean {
  switch (a.type) {
    case 'pen':
    case 'highlighter':
      return false;
    case 'line':
    case 'arrow':
      return a.points.length < 2 || Math.hypot(a.points[0].x - a.points[1].x, a.points[0].y - a.points[1].y) < 3;
    default: {
      const f = standardize(a.frame);
      return f.w < 3 || f.h < 3;
    }
  }
}

export function clampPoint(p: Point, size: Size): Point {
  return { x: Math.min(Math.max(p.x, 0), size.w), y: Math.min(Math.max(p.y, 0), size.h) };
}

/** Zoom that fits `content` into `viewport` with 32 px of room on each side, never above 100 %. */
export function fitZoom(content: Size, viewport: Size): number {
  if (content.w <= 0 || content.h <= 0) return 1;
  const fit = Math.min((viewport.w - 64) / content.w, (viewport.h - 64) / content.h);
  return Math.min(Math.max(fit, MIN_ZOOM), 1);
}

export const MIN_ZOOM = 0.05;
export const MAX_ZOOM = 8;
export const clampZoom = (z: number) => Math.min(Math.max(z, MIN_ZOOM), MAX_ZOOM);
