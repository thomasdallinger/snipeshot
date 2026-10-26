// A capture being edited: the untouched original plus a list of edits (MarkupDocument.swift).
// Annotations are immutable values: every change replaces the object, so undo snapshots can share them.
import { makeLayout, type CanvasLayout } from './geometry';
import {
  cloneAnnotation,
  CURRENT_FORMAT,
  defaultBackdrop,
  hasEdits,
  newId,
  offsetAnnotation,
  type Annotation,
  type Backdrop,
  type EditFile,
  type Rect,
  type Size,
} from './model';

export const UNDO_LIMIT = 200;
export const SAVE_DELAY_MS = 400;

interface Snapshot {
  annotations: Annotation[];
  crop: Rect | null;
  backdrop: Backdrop;
}

export interface DocumentInit {
  path: string;
  /** Image size in points. */
  pointSize: Size;
  /** Pixels per point. */
  scale: number;
  edits: EditFile | null;
  /** Persists the edits (edit file and flattened PNG). Called at most once at a time. */
  save: (file: EditFile) => Promise<void>;
}

export class MarkupDocument {
  readonly path: string;
  readonly pointSize: Size;
  readonly scale: number;

  annotations = $state.raw<Annotation[]>([]);
  selectionId = $state<string | null>(null);
  crop = $state.raw<Rect | null>(null);
  backdrop = $state.raw<Backdrop>(defaultBackdrop());
  isSaved = $state(true);

  #past = $state.raw<Snapshot[]>([]);
  #future = $state.raw<Snapshot[]>([]);
  canUndo = $derived(this.#past.length > 0);
  canRedo = $derived(this.#future.length > 0);

  #save: DocumentInit['save'];
  #timer: ReturnType<typeof setTimeout> | null = null;
  #saving: Promise<void> = Promise.resolve();

  constructor(init: DocumentInit) {
    this.path = init.path;
    this.pointSize = init.pointSize;
    this.scale = init.scale;
    this.#save = init.save;
    this.annotations = init.edits?.annotations ?? [];
    this.crop = init.edits?.crop ?? null;
    this.backdrop = init.edits?.backdrop ?? defaultBackdrop();
  }

  get editFile(): EditFile {
    return { format: CURRENT_FORMAT, scale: this.scale, annotations: this.annotations, crop: this.crop, backdrop: this.backdrop };
  }

  get hasEdits(): boolean {
    return hasEdits(this);
  }

  layout(showFullImage = false): CanvasLayout {
    return makeLayout(this.pointSize, this.crop, this.backdrop, showFullImage);
  }

  get selectedItem(): Annotation | null {
    return this.annotations.find((a) => a.id === this.selectionId) ?? null;
  }

  find(id: string | null): Annotation | null {
    return id ? (this.annotations.find((a) => a.id === id) ?? null) : null;
  }

  // ---------------------------------------------------------------- undo

  get #snapshot(): Snapshot {
    return { annotations: this.annotations, crop: this.crop, backdrop: this.backdrop };
  }

  /** Call before every user-visible change so it can be undone. */
  registerUndo(): void {
    const past = [...this.#past, this.#snapshot];
    this.#past = past.length > UNDO_LIMIT ? past.slice(past.length - UNDO_LIMIT) : past;
    this.#future = [];
  }

  /** Call when a change is finished (end of a drag, a toggle) to persist it. */
  didChange(): void {
    this.scheduleSave();
  }

  undo(): void {
    const previous = this.#past.at(-1);
    if (!previous) return;
    this.#past = this.#past.slice(0, -1);
    this.#future = [...this.#future, this.#snapshot];
    this.#restore(previous);
  }

  redo(): void {
    const next = this.#future.at(-1);
    if (!next) return;
    this.#future = this.#future.slice(0, -1);
    this.#past = [...this.#past, this.#snapshot];
    this.#restore(next);
  }

  #restore(s: Snapshot) {
    this.annotations = s.annotations;
    this.crop = s.crop;
    this.backdrop = s.backdrop;
    if (this.selectionId && !this.find(this.selectionId)) this.selectionId = null;
    this.scheduleSave();
  }

  // ---------------------------------------------------------------- annotations

  /** Replaces one annotation with an edited copy. No undo step by itself. */
  update(id: string, body: (a: Annotation) => void): void {
    this.annotations = this.annotations.map((a) => {
      if (a.id !== id) return a;
      const copy = cloneAnnotation(a);
      body(copy);
      return copy;
    });
  }

  /** Moves one annotation; cheaper than `update` for drags. */
  offset(id: string, dx: number, dy: number): void {
    this.annotations = this.annotations.map((a) => (a.id === id ? offsetAnnotation(a, dx, dy) : a));
  }

  add(a: Annotation): void {
    this.annotations = [...this.annotations, a];
  }

  /** Drops an annotation without an undo step (degenerate shapes, empty text). */
  remove(id: string): void {
    this.annotations = this.annotations.filter((a) => a.id !== id);
    if (this.selectionId === id) this.selectionId = null;
  }

  delete(id: string): void {
    this.registerUndo();
    this.remove(id);
    this.didChange();
  }

  duplicate(id: string): void {
    const original = this.find(id);
    if (!original) return;
    this.registerUndo();
    const copy = { ...offsetAnnotation(original, 16, 16), id: newId() };
    if (copy.type === 'step') copy.step = this.nextStep;
    this.add(copy);
    this.selectionId = copy.id;
    this.didChange();
  }

  bringToFront(id: string): void {
    const i = this.annotations.findIndex((a) => a.id === id);
    if (i < 0 || i === this.annotations.length - 1) return;
    this.registerUndo();
    const list = [...this.annotations];
    list.push(...list.splice(i, 1));
    this.annotations = list;
    this.didChange();
  }

  sendToBack(id: string): void {
    const i = this.annotations.findIndex((a) => a.id === id);
    if (i <= 0) return;
    this.registerUndo();
    const list = [...this.annotations];
    list.unshift(...list.splice(i, 1));
    this.annotations = list;
    this.didChange();
  }

  get nextStep(): number {
    return Math.max(0, ...this.annotations.filter((a) => a.type === 'step').map((a) => a.step)) + 1;
  }

  // ---------------------------------------------------------------- persistence

  scheduleSave(): void {
    if (this.#timer) clearTimeout(this.#timer);
    this.isSaved = false;
    this.#timer = setTimeout(() => void this.saveNow(), SAVE_DELAY_MS);
  }

  /** Writes now; resolves when this and any earlier save are done. */
  saveNow(): Promise<void> {
    if (this.#timer) clearTimeout(this.#timer);
    this.#timer = null;
    const file = this.editFile;
    this.#saving = this.#saving
      .then(() => this.#save(file))
      .catch((e) => console.error('Saving edits failed', e))
      .then(() => {
        // A newer change may have been scheduled meanwhile.
        if (!this.#timer) this.isSaved = true;
      });
    return this.#saving;
  }

  /** Saves only if something is pending. */
  flush(): Promise<void> {
    return this.#timer ? this.saveNow() : this.#saving;
  }
}
