// Canvas 2D port of Renderer.swift: the only renderer of edits on Windows. Draws in canvas points
// (y-down); callers set the transform from points to device pixels (zoom × DPR, or the capture scale
// when flattening).
import { canvasSize, docRectToCanvas, docToCanvas, imageFrame, rectHandles, type CanvasLayout, type Handle } from './geometry';
import {
  annotationBounds,
  isBoxed,
  isLight,
  isSegment,
  PRESET_COLORS,
  standardize,
  withAlpha,
  type Annotation,
  type BackdropFill,
  type Point,
  type Rect,
  type Size,
} from './model';

type Ctx = CanvasRenderingContext2D;

export const TEXT_FONT = "'Segoe UI Variable Display', 'Segoe UI', system-ui, sans-serif";
/** Line height as a multiple of the text size; the editing field uses the same. */
export const TEXT_LINE_HEIGHT = 1.25;
const textFont = (size: number) => `600 ${size}px ${TEXT_FONT}`;

// ---------------------------------------------------------------- source

/** Pixelated and blurred copies of the original image for redaction, built once per image. */
export class RedactionEffects {
  private pixelated: HTMLCanvasElement | null = null;
  private blurred: HTMLCanvasElement | null = null;

  constructor(private readonly src: Pick<RenderSource, 'image' | 'pixelWidth' | 'pixelHeight' | 'scale'>) {}

  get(style: 'pixelate' | 'blur'): HTMLCanvasElement {
    if (style === 'pixelate') return (this.pixelated ??= pixelate(this.src, Math.max(8, 12 * this.src.scale)));
    return (this.blurred ??= blur(this.src, Math.max(10, 14 * this.src.scale)));
  }
}

export interface RenderSource {
  image: CanvasImageSource;
  /** True pixel size; image elements may report a DPI-adjusted natural size. */
  pixelWidth: number;
  pixelHeight: number;
  /** Image size in points; annotations live in this space. */
  pointSize: Size;
  /** Pixels per point. */
  scale: number;
  effects: RedactionEffects;
}

export function makeSource(image: CanvasImageSource, pixelWidth: number, pixelHeight: number, scale: number): RenderSource {
  const s = Math.max(scale, 0.25);
  const base = { image, pixelWidth, pixelHeight, scale: s };
  return { ...base, pointSize: { w: pixelWidth / s, h: pixelHeight / s }, effects: new RedactionEffects(base) };
}

function canvas(w: number, h: number): HTMLCanvasElement {
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.round(w));
  c.height = Math.max(1, Math.round(h));
  return c;
}

function ctx2d(c: HTMLCanvasElement): Ctx {
  return c.getContext('2d', { willReadFrequently: false })!;
}

/** Halves step by step so a big downscale averages pixels instead of sampling a few. */
function downscale(src: CanvasImageSource, w: number, h: number, tw: number, th: number): HTMLCanvasElement {
  let cur: CanvasImageSource = src;
  let cw = w,
    ch = h;
  while (cw / 2 > tw && ch / 2 > th) {
    const next = canvas(cw / 2, ch / 2);
    const c = ctx2d(next);
    c.imageSmoothingQuality = 'high';
    c.drawImage(cur, 0, 0, cw, ch, 0, 0, next.width, next.height);
    cur = next;
    cw = next.width;
    ch = next.height;
  }
  const out = canvas(tw, th);
  const c = ctx2d(out);
  c.imageSmoothingQuality = 'high';
  c.drawImage(cur, 0, 0, cw, ch, 0, 0, out.width, out.height);
  return out;
}

/** CIPixellate equivalent: square blocks of `block` pixels anchored at the top-left. */
function pixelate(src: Pick<RenderSource, 'image' | 'pixelWidth' | 'pixelHeight'>, block: number): HTMLCanvasElement {
  const W = src.pixelWidth,
    H = src.pixelHeight;
  const cols = Math.ceil(W / block),
    rows = Math.ceil(H / block);
  // Scale the image so the grid divides it evenly; edge blocks then average the image's last pixels.
  const full = canvas(cols * block, rows * block);
  const fc = ctx2d(full);
  fc.drawImage(src.image, 0, 0, W, H, 0, 0, W, H);
  fc.drawImage(src.image, W - 1, 0, 1, H, W, 0, full.width - W, H);
  fc.drawImage(src.image, 0, H - 1, W, 1, 0, H, W, full.height - H);
  fc.drawImage(src.image, W - 1, H - 1, 1, 1, W, H, full.width - W, full.height - H);
  const small = downscale(full, full.width, full.height, cols, rows);
  const out = canvas(W, H);
  const c = ctx2d(out);
  c.imageSmoothingEnabled = false;
  c.drawImage(small, 0, 0, cols, rows, 0, 0, cols * block, rows * block);
  return out;
}

/** Gaussian blur with the edges clamped (like `clampedToExtent`), so borders do not fade out. */
function blur(src: Pick<RenderSource, 'image' | 'pixelWidth' | 'pixelHeight'>, radius: number): HTMLCanvasElement {
  const W = src.pixelWidth,
    H = src.pixelHeight;
  const p = Math.ceil(radius * 3);
  const padded = canvas(W + 2 * p, H + 2 * p);
  const pc = ctx2d(padded);
  const img = src.image;
  pc.drawImage(img, 0, 0, W, H, p, p, W, H);
  pc.drawImage(img, 0, 0, W, 1, p, 0, W, p);
  pc.drawImage(img, 0, H - 1, W, 1, p, p + H, W, p);
  pc.drawImage(img, 0, 0, 1, H, 0, p, p, H);
  pc.drawImage(img, W - 1, 0, 1, H, p + W, p, p, H);
  pc.drawImage(img, 0, 0, 1, 1, 0, 0, p, p);
  pc.drawImage(img, W - 1, 0, 1, 1, p + W, 0, p, p);
  pc.drawImage(img, 0, H - 1, 1, 1, 0, p + H, p, p);
  pc.drawImage(img, W - 1, H - 1, 1, 1, p + W, p + H, p, p);

  const out = canvas(W, H);
  const c = ctx2d(out);
  if (typeof c.filter === 'string') {
    c.filter = `blur(${radius}px)`;
    c.drawImage(padded, -p, -p);
    c.filter = 'none';
  } else {
    // No canvas filters: a heavy down-and-up scale is a passable box blur.
    const f = Math.max(2, radius / 2);
    const small = downscale(padded, padded.width, padded.height, padded.width / f, padded.height / f);
    c.imageSmoothingQuality = 'high';
    c.drawImage(small, 0, 0, small.width, small.height, -p, -p, padded.width, padded.height);
  }
  return out;
}

// ---------------------------------------------------------------- whole canvas

/** Device pixels per canvas point of the current transform (shadows are not transformed). */
const deviceScale = (ctx: Ctx) => Math.hypot(ctx.getTransform().a, ctx.getTransform().b) || 1;

/** Draws backdrop, image and annotations in canvas coordinates. */
export function drawCanvas(
  ctx: Ctx,
  src: RenderSource,
  layout: CanvasLayout,
  annotations: Annotation[],
  hiddenId: string | null = null,
): void {
  const frame = imageFrame(layout);
  const bd = layout.backdrop;
  const k = deviceScale(ctx);
  if (bd) {
    drawBackdrop(ctx, bd.fill, canvasSize(layout));
    if (bd.shadow) {
      ctx.save();
      ctx.shadowColor = 'rgba(0, 0, 0, 0.22)';
      ctx.shadowBlur = 24 * k;
      ctx.shadowOffsetY = 6 * k;
      ctx.fillStyle = '#000';
      roundRectPath(ctx, frame, bd.radius);
      ctx.fill();
      ctx.restore();
    }
  }

  ctx.save();
  if (bd && bd.radius > 0) roundRectPath(ctx, frame, bd.radius);
  else {
    ctx.beginPath();
    ctx.rect(frame.x, frame.y, frame.w, frame.h);
  }
  ctx.clip();
  // Move into document space: the content origin lands on the image frame.
  ctx.translate(layout.padding - layout.contentRect.x, layout.padding - layout.contentRect.y);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(src.image, 0, 0, src.pixelWidth, src.pixelHeight, 0, 0, src.pointSize.w, src.pointSize.h);
  for (const a of annotations) {
    if (a.id !== hiddenId) drawAnnotation(ctx, a, src);
  }
  ctx.restore();
}

export function drawBackdrop(ctx: Ctx, fill: BackdropFill, size: Size): void {
  if (fill.kind === 'color') {
    ctx.fillStyle = fill.color;
  } else {
    const [top, bottom] = PRESET_COLORS[fill.preset];
    const g = ctx.createLinearGradient(0, 0, 0, size.h);
    g.addColorStop(0, top);
    g.addColorStop(1, bottom);
    ctx.fillStyle = g;
  }
  ctx.fillRect(0, 0, size.w, size.h);
}

export function roundRectPath(ctx: Ctx, r: Rect, radius: number): void {
  const rad = Math.max(0, Math.min(radius, r.w / 2, r.h / 2));
  ctx.beginPath();
  ctx.moveTo(r.x + rad, r.y);
  ctx.arcTo(r.x + r.w, r.y, r.x + r.w, r.y + r.h, rad);
  ctx.arcTo(r.x + r.w, r.y + r.h, r.x, r.y + r.h, rad);
  ctx.arcTo(r.x, r.y + r.h, r.x, r.y, rad);
  ctx.arcTo(r.x, r.y, r.x + r.w, r.y, rad);
  ctx.closePath();
}

// ---------------------------------------------------------------- annotations

export function drawAnnotation(ctx: Ctx, a: Annotation, src: RenderSource): void {
  ctx.save();
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  switch (a.type) {
    case 'rectangle': {
      const r = standardize(a.frame);
      const radius = Math.min(Math.max(a.stroke, 4), Math.min(r.w, r.h) / 2);
      if (a.filled) {
        ctx.fillStyle = a.color;
        roundRectPath(ctx, r, radius);
        ctx.fill();
      } else {
        const ins = { x: r.x + a.stroke / 2, y: r.y + a.stroke / 2, w: r.w - a.stroke, h: r.h - a.stroke };
        if (ins.w <= 0 || ins.h <= 0) break;
        ctx.strokeStyle = a.color;
        ctx.lineWidth = a.stroke;
        const ir = Math.max(0, Math.min(radius - a.stroke / 2, Math.min(ins.w, ins.h) / 2));
        roundRectPath(ctx, ins, ir);
        ctx.stroke();
      }
      break;
    }
    case 'ellipse': {
      const r = standardize(a.frame);
      if (a.filled) {
        ctx.fillStyle = a.color;
        ellipsePath(ctx, r);
        ctx.fill();
      } else {
        const ins = { x: r.x + a.stroke / 2, y: r.y + a.stroke / 2, w: r.w - a.stroke, h: r.h - a.stroke };
        if (ins.w <= 0 || ins.h <= 0) break;
        ctx.strokeStyle = a.color;
        ctx.lineWidth = a.stroke;
        ellipsePath(ctx, ins);
        ctx.stroke();
      }
      break;
    }
    case 'line':
      if (a.points.length < 2) break;
      ctx.strokeStyle = a.color;
      ctx.lineWidth = a.stroke;
      ctx.beginPath();
      ctx.moveTo(a.points[0].x, a.points[0].y);
      ctx.lineTo(a.points[1].x, a.points[1].y);
      ctx.stroke();
      break;
    case 'arrow':
      if (a.points.length < 2) break;
      ctx.fillStyle = a.color;
      arrowPath(ctx, a.points[0], a.points[1], a.stroke);
      ctx.fill();
      break;
    case 'pen':
    case 'highlighter': {
      if (a.points.length === 0) break;
      const highlighter = a.type === 'highlighter';
      ctx.strokeStyle = highlighter ? withAlpha(a.color, 0.38) : a.color;
      ctx.lineWidth = highlighter ? Math.max(a.stroke * 3, 14) : a.stroke;
      if (highlighter) {
        ctx.globalCompositeOperation = 'multiply';
        ctx.lineCap = 'butt';
      }
      smoothPath(ctx, a.points);
      ctx.stroke();
      break;
    }
    case 'text':
      drawText(ctx, a);
      break;
    case 'step': {
      const r = standardize(a.frame);
      ctx.fillStyle = a.color;
      ellipsePath(ctx, r);
      ctx.fill();
      const label = String(a.step);
      ctx.font = textFont(r.h * 0.5);
      ctx.fillStyle = isLight(a.color) ? '#000' : '#fff';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'alphabetic';
      // Centre the digits' ink, not the font's em box.
      const m = ctx.measureText(label);
      const ascent = m.actualBoundingBoxAscent,
        descent = m.actualBoundingBoxDescent;
      ctx.fillText(label, r.x + r.w / 2, r.y + r.h / 2 + (ascent - descent) / 2);
      break;
    }
    case 'redaction': {
      const r = standardize(a.frame);
      if (a.redaction === 'blackout') {
        ctx.fillStyle = '#000';
        ctx.fillRect(r.x, r.y, r.w, r.h);
      } else {
        ctx.beginPath();
        ctx.rect(r.x, r.y, r.w, r.h);
        ctx.clip();
        ctx.imageSmoothingEnabled = a.redaction !== 'pixelate';
        const effect = src.effects.get(a.redaction);
        ctx.drawImage(effect, 0, 0, effect.width, effect.height, 0, 0, src.pointSize.w, src.pointSize.h);
      }
      break;
    }
  }
  ctx.restore();
}

function ellipsePath(ctx: Ctx, r: Rect) {
  ctx.beginPath();
  ctx.ellipse(r.x + r.w / 2, r.y + r.h / 2, Math.max(r.w / 2, 0), Math.max(r.h / 2, 0), 0, 0, Math.PI * 2);
}

/** Tapered shaft plus a solid head, sized from the stroke width. */
export function arrowPath(ctx: Ctx, start: Point, end: Point, width: number): void {
  const dx = end.x - start.x,
    dy = end.y - start.y;
  const length = Math.max(Math.hypot(dx, dy), 0.001);
  const ux = dx / length,
    uy = dy / length;
  const nx = -uy,
    ny = ux;
  const headLength = Math.min(Math.max(width * 3.6, 14), length * 0.6);
  const headHalf = Math.max(width * 2.0, 8);
  const base = { x: end.x - ux * headLength, y: end.y - uy * headLength };
  const tail = Math.max(width * 0.25, 0.75);
  const neck = width * 0.6;

  ctx.beginPath();
  ctx.moveTo(start.x + nx * tail, start.y + ny * tail);
  ctx.lineTo(base.x + nx * neck, base.y + ny * neck);
  ctx.lineTo(base.x + nx * headHalf, base.y + ny * headHalf);
  ctx.lineTo(end.x, end.y);
  ctx.lineTo(base.x - nx * headHalf, base.y - ny * headHalf);
  ctx.lineTo(base.x - nx * neck, base.y - ny * neck);
  ctx.lineTo(start.x - nx * tail, start.y - ny * tail);
  ctx.arc(start.x, start.y, tail, Math.atan2(-ny, -nx), Math.atan2(ny, nx), false);
  ctx.closePath();
}

/** Quadratic smoothing through midpoints keeps freehand strokes from looking jagged. */
export function smoothPath(ctx: Ctx, points: Point[]): void {
  ctx.beginPath();
  const first = points[0];
  ctx.moveTo(first.x, first.y);
  if (points.length === 1) {
    ctx.lineTo(first.x, first.y);
    return;
  }
  if (points.length === 2) {
    ctx.lineTo(points[1].x, points[1].y);
    return;
  }
  for (let i = 1; i < points.length - 1; i++) {
    const mid = { x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2 };
    ctx.quadraticCurveTo(points[i].x, points[i].y, mid.x, mid.y);
  }
  const last = points[points.length - 1];
  ctx.lineTo(last.x, last.y);
}

// ---------------------------------------------------------------- text

let measureCtx: Ctx | null = null;

/** Size of a text annotation's frame: the widest line plus 4, lines × line height. */
export function measureText(text: string, textSize: number): Size {
  measureCtx ??= ctx2d(canvas(1, 1));
  measureCtx.font = textFont(textSize);
  const lines = (text === '' ? ' ' : text).split('\n');
  const width = Math.max(...lines.map((l) => measureCtx!.measureText(l || ' ').width));
  return { w: Math.ceil(width) + 4, h: Math.ceil(lines.length * textSize * TEXT_LINE_HEIGHT) };
}

function drawText(ctx: Ctx, a: Annotation) {
  if (!a.text) return;
  const k = deviceScale(ctx);
  const lh = a.textSize * TEXT_LINE_HEIGHT;
  ctx.font = textFont(a.textSize);
  ctx.fillStyle = a.color;
  // A faint halo keeps text readable on busy screenshots without looking like an effect.
  ctx.shadowColor = isLight(a.color) ? 'rgba(0, 0, 0, 0.35)' : 'rgba(255, 255, 255, 0.35)';
  ctx.shadowBlur = Math.max(1.5, a.textSize * 0.06) * k;
  ctx.textBaseline = 'middle';
  ctx.textAlign = 'left';
  a.text.split('\n').forEach((line, i) => {
    ctx.fillText(line, a.frame.x + 2, a.frame.y + i * lh + lh / 2);
  });
}

// ---------------------------------------------------------------- overlays (editor only)

/**
 * Selection outline and handles. `px` converts screen pixels to canvas units (1 / zoom), so chrome keeps
 * its size at every zoom level.
 */
export function drawSelection(ctx: Ctx, a: Annotation, layout: CanvasLayout, px: number, accent: string): void {
  ctx.save();
  if (!isSegment(a.type)) {
    const b = docRectToCanvas(layout, annotationBounds(a));
    ctx.strokeStyle = accent;
    ctx.lineWidth = px;
    ctx.strokeRect(b.x - 3 * px, b.y - 3 * px, b.w + 6 * px, b.h + 6 * px);
  }
  for (const [, r] of handleRects(a, layout, px)) drawHandle(ctx, r, px, accent);
  ctx.restore();
}

function drawHandle(ctx: Ctx, r: Rect, px: number, stroke: string) {
  ctx.fillStyle = '#fff';
  ctx.fillRect(r.x, r.y, r.w, r.h);
  ctx.strokeStyle = stroke;
  ctx.lineWidth = px;
  ctx.strokeRect(r.x + px / 2, r.y + px / 2, r.w - px, r.h - px);
}

export function handleRects(a: Annotation, layout: CanvasLayout, px: number): [Handle, Rect][] {
  const s = 7 * px;
  const box = (p: Point): Rect => ({ x: p.x - s / 2, y: p.y - s / 2, w: s, h: s });
  const toCanvas = (p: Point) => docToCanvas(layout, p);
  if (isSegment(a.type) && a.points.length >= 2) {
    return [
      ['lineStart', box(toCanvas(a.points[0]))],
      ['lineEnd', box(toCanvas(a.points[1]))],
    ];
  }
  if (!isBoxed(a.type)) return [];
  return rectHandles(docRectToCanvas(layout, standardize(a.frame))).map(([h, p]) => [h, box(p)]);
}

/** Dimmed outside, rule of thirds, white edge with handles and the pixel size below. */
export function drawCropOverlay(ctx: Ctx, draft: Rect, layout: CanvasLayout, px: number, scale: number): void {
  const r = docRectToCanvas(layout, standardize(draft));
  const size = canvasSize(layout);
  ctx.save();
  ctx.fillStyle = 'rgba(0, 0, 0, 0.5)';
  ctx.beginPath();
  ctx.rect(0, 0, size.w, size.h);
  ctx.rect(r.x, r.y, r.w, r.h);
  ctx.fill('evenodd');

  ctx.strokeStyle = 'rgba(255, 255, 255, 0.25)';
  ctx.lineWidth = px;
  ctx.beginPath();
  for (let i = 1; i <= 2; i++) {
    const x = r.x + (r.w * i) / 3,
      y = r.y + (r.h * i) / 3;
    ctx.moveTo(x, r.y);
    ctx.lineTo(x, r.y + r.h);
    ctx.moveTo(r.x, y);
    ctx.lineTo(r.x + r.w, y);
  }
  ctx.stroke();

  ctx.strokeStyle = '#fff';
  ctx.strokeRect(r.x, r.y, r.w, r.h);
  const s = 7 * px;
  for (const [, p] of rectHandles(r)) drawHandle(ctx, { x: p.x - s / 2, y: p.y - s / 2, w: s, h: s }, px, '#fff');

  const label = `${Math.round(draft.w * scale)} × ${Math.round(draft.h * scale)}`;
  ctx.font = `500 ${11 * px}px ${TEXT_FONT}`;
  const tw = ctx.measureText(label).width;
  const tag = { x: r.x, y: r.y + r.h + 6 * px, w: tw + 10 * px, h: 18 * px };
  ctx.fillStyle = 'rgba(0, 0, 0, 0.75)';
  roundRectPath(ctx, tag, 4 * px);
  ctx.fill();
  ctx.fillStyle = '#fff';
  ctx.textBaseline = 'middle';
  ctx.fillText(label, tag.x + 5 * px, tag.y + tag.h / 2);
  ctx.restore();
}

// ---------------------------------------------------------------- export

/** Renders the edited capture at full pixel resolution. */
export function flattenToCanvas(src: RenderSource, layout: CanvasLayout, annotations: Annotation[]): HTMLCanvasElement {
  const size = canvasSize(layout);
  const out = canvas(Math.round(size.w * src.scale), Math.round(size.h * src.scale));
  const ctx = ctx2d(out);
  ctx.scale(src.scale, src.scale);
  drawCanvas(ctx, src, layout, annotations);
  return out;
}

export async function canvasToPng(c: HTMLCanvasElement): Promise<Uint8Array> {
  const blob = await new Promise<Blob | null>((resolve) => c.toBlob(resolve, 'image/png'));
  if (!blob) throw new Error('Could not encode the image.');
  return new Uint8Array(await blob.arrayBuffer());
}
