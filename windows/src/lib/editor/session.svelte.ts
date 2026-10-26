// One open capture: connects the chrome (header, inspector, status bar) with the canvas (EditSession.swift).
import { api } from '../api';
import { baseName } from '../format';
import type { CaptureFile } from '../types';
import { MarkupDocument } from './document.svelte';
import { loadImage, persistEdits, renderFlattened } from './flatten';
import { canvasSize, clampZoom, fitZoom, rectEquals, intersect, integral, type CanvasLayout } from './geometry';
import {
  decodeEditFile,
  DEFAULT_COLOR,
  canFill,
  usesStroke,
  usesTextSize,
  type Annotation,
  type AnnotationType,
  type Backdrop,
  type Rect,
  type Redaction,
} from './model';
import { makeSource, measureText, type RenderSource } from './renderer';
import { TOOL_INFO, type Tool } from './tools';

/** What the canvas component lends the session. */
export interface CanvasHooks {
  endTextSession(): void;
  viewportSize(): { w: number; h: number };
  /** Applies a zoom level, keeping the visible centre in place. */
  setZoom(zoom: number): void;
  focus(): void;
}

export class EditSession {
  readonly document: MarkupDocument;
  readonly source: RenderSource;
  readonly capture: CaptureFile;

  // ToolSettings.swift: the current tool and the style new annotations get.
  tool = $state<Tool>('arrow');
  color = $state(DEFAULT_COLOR);
  stroke = $state(4);
  textSize = $state(28);
  filled = $state(false);
  redaction = $state<Redaction>('pixelate');
  pendingCrop = $state.raw<Rect | null>(null);
  /** Short status message shown in the status bar ("Copied"). */
  notice = $state<string | null>(null);
  zoom = $state(1);

  canvas: CanvasHooks | null = null;
  onDelete: ((path: string) => void) | null = null;

  #toolBeforeCrop: Tool = 'arrow';
  #lastContinuousEdit = 0;
  #noticeTimer: ReturnType<typeof setTimeout> | null = null;

  isCropping = $derived(this.tool === 'crop');
  /** Crop shows the whole image without backdrop so the edges can be moved anywhere. */
  get displayLayout(): CanvasLayout {
    return this.document.layout(this.isCropping);
  }

  private constructor(capture: CaptureFile, source: RenderSource, document: MarkupDocument) {
    this.capture = capture;
    this.source = source;
    this.document = document;
  }

  static async open(capture: CaptureFile): Promise<EditSession> {
    const [img, json] = await Promise.all([loadImage(capture.path, capture.modifiedAt), api.readEdits(capture.path)]);
    const edits = json ? decodeEditFile(json) : null;
    const source = makeSource(img, capture.width, capture.height, edits?.scale ?? capture.scale);
    const doc = new MarkupDocument({
      path: capture.path,
      pointSize: source.pointSize,
      scale: source.scale,
      edits,
      save: (file) => persistEdits(capture.path, source, file),
    });
    return new EditSession(capture, source, doc);
  }

  // ---------------------------------------------------------------- tools

  selectTool(tool: Tool): void {
    if (tool === this.tool) return;
    this.canvas?.endTextSession();
    if (this.isCropping) this.applyCrop(tool);
    if (tool === 'crop') {
      this.#beginCrop();
      return;
    }
    this.tool = tool;
    if (tool !== 'select') this.document.selectionId = null;
    this.canvas?.focus();
  }

  notify(message: string): void {
    if (this.#noticeTimer) clearTimeout(this.#noticeTimer);
    this.notice = message;
    this.#noticeTimer = setTimeout(() => (this.notice = null), 2000);
  }

  // ---------------------------------------------------------------- style (also applied to the selection)

  /** What the inspector shows: the selection's type, or what the current tool would create. */
  get styleTarget(): AnnotationType | null {
    return this.document.selectedItem?.type ?? TOOL_INFO[this.tool].type;
  }

  get currentColor() {
    return this.document.selectedItem?.color ?? this.color;
  }
  get currentStroke() {
    return this.document.selectedItem?.stroke ?? this.stroke;
  }
  get currentTextSize() {
    return this.document.selectedItem?.textSize ?? this.textSize;
  }
  get currentFilled() {
    return this.document.selectedItem?.filled ?? this.filled;
  }
  get currentRedaction() {
    return this.document.selectedItem?.redaction ?? this.redaction;
  }

  setColor(c: string): void {
    this.color = c;
    this.#applyToSelection((a) => (a.color = c));
  }

  setStroke(w: number): void {
    this.stroke = w;
    this.#applyToSelection((a) => {
      if (usesStroke(a.type)) a.stroke = w;
    });
  }

  setTextSize(size: number): void {
    this.textSize = size;
    this.#applyToSelection((a) => {
      if (!usesTextSize(a.type)) return;
      const cx = a.frame.x + a.frame.w / 2,
        cy = a.frame.y + a.frame.h / 2;
      a.textSize = size;
      if (a.type === 'text') {
        const m = measureText(a.text, size);
        a.frame = { ...a.frame, w: m.w, h: m.h };
      } else {
        a.frame = { x: cx - size / 2, y: cy - size / 2, w: size, h: size };
      }
    });
  }

  setFilled(filled: boolean): void {
    this.filled = filled;
    this.#applyToSelection((a) => {
      if (canFill(a.type)) a.filled = filled;
    });
  }

  setRedaction(r: Redaction): void {
    this.redaction = r;
    this.#applyToSelection((a) => {
      if (a.type === 'redaction') a.redaction = r;
    });
  }

  #applyToSelection(body: (a: Annotation) => void) {
    const id = this.document.selectionId;
    if (!id) return;
    this.document.registerUndo();
    this.document.update(id, body);
    this.document.didChange();
  }

  // ---------------------------------------------------------------- crop

  #beginCrop() {
    this.#toolBeforeCrop = this.tool;
    this.document.selectionId = null;
    const d = this.document;
    this.pendingCrop = d.crop ?? { x: 0, y: 0, w: d.pointSize.w, h: d.pointSize.h };
    this.tool = 'crop';
    this.canvas?.focus();
  }

  /** Keeps the drafted crop and leaves crop mode. */
  applyCrop(next: Tool | null = null): void {
    if (!this.isCropping) return;
    const d = this.document;
    const full = { x: 0, y: 0, w: d.pointSize.w, h: d.pointSize.h };
    let crop: Rect | null = this.pendingCrop ? intersect(integral(this.pendingCrop), full) : null;
    if (crop && (crop.w < 4 || crop.h < 4 || rectEquals(crop, full))) crop = null;
    if (!rectEquals(crop, d.crop)) {
      d.registerUndo();
      d.crop = crop;
      d.didChange();
    }
    this.#leaveCrop(next);
  }

  cancelCrop(): void {
    if (this.isCropping) this.#leaveCrop(null);
  }

  #leaveCrop(next: Tool | null) {
    this.pendingCrop = null;
    this.tool = next ?? (this.#toolBeforeCrop === 'crop' ? 'select' : this.#toolBeforeCrop);
  }

  resetCropDraft(): void {
    const d = this.document;
    this.pendingCrop = { x: 0, y: 0, w: d.pointSize.w, h: d.pointSize.h };
  }

  removeCrop(): void {
    const d = this.document;
    if (!d.crop) return;
    d.registerUndo();
    d.crop = null;
    d.didChange();
  }

  // ---------------------------------------------------------------- backdrop

  /** `continuous` edits (slider drags) collapse into one undo step per gesture. */
  updateBackdrop(patch: Partial<Backdrop>, continuous = false): void {
    const now = Date.now();
    if (!continuous || now - this.#lastContinuousEdit > 600) this.document.registerUndo();
    if (continuous) this.#lastContinuousEdit = now;
    this.document.backdrop = { ...this.document.backdrop, ...patch };
    this.document.didChange();
  }

  // ---------------------------------------------------------------- undo

  undo(): void {
    this.canvas?.endTextSession();
    this.document.undo();
  }

  redo(): void {
    this.canvas?.endTextSession();
    this.document.redo();
  }

  // ---------------------------------------------------------------- output

  async copyToClipboard(): Promise<void> {
    this.canvas?.endTextSession();
    try {
      if (this.document.hasEdits) await api.copyPng(await renderFlattened(this.source, this.document.editFile));
      else await api.copyCapture(this.document.path);
      this.notify('Copied');
    } catch (e) {
      console.error(e);
      this.notify('Could not copy');
    }
  }

  async export(): Promise<void> {
    this.canvas?.endTextSession();
    // Rust exports the flattened cache, so it has to be current first.
    await this.document.flush();
    const written = await api.exportCapture(this.document.path).catch((e) => {
      console.error(e);
      return null;
    });
    if (written) this.notify(`Exported ${baseName(written)}`);
  }

  revealInExplorer(): void {
    void api.showInExplorer(this.document.path);
  }

  async pin(): Promise<void> {
    this.canvas?.endTextSession();
    await this.document.saveNow();
    await api.pinCapture(this.document.path);
  }

  delete(): void {
    this.onDelete?.(this.document.path);
  }

  async save(): Promise<void> {
    await this.document.saveNow();
    this.notify('Saved');
  }

  /** Persist everything before the session goes away. */
  close(): Promise<void> {
    this.canvas?.endTextSession();
    if (this.isCropping) this.applyCrop();
    return this.document.flush();
  }

  // ---------------------------------------------------------------- zoom

  zoomIn = () => this.setZoom(this.zoom * 1.25);
  zoomOut = () => this.setZoom(this.zoom / 1.25);
  zoomActualSize = () => this.setZoom(1);

  zoomToFit = () => {
    const vp = this.canvas?.viewportSize();
    if (!vp) return;
    this.setZoom(fitZoom(canvasSize(this.displayLayout), vp));
  };

  setZoom(z: number): void {
    const clamped = clampZoom(z);
    if (this.canvas) this.canvas.setZoom(clamped);
    else this.zoom = clamped;
  }
}
