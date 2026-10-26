// Makes an element a drag source for a capture file (shelf cards, library rows). Port of
// FileDragSourceView.swift: a click opens, a move of more than 4 px hands the drag to Rust (OLE).
import type { Action } from 'svelte/action';
import { api } from './api';

export interface FileDragOptions {
  path: string;
  onclick?: () => void;
  ondragstart?: () => void;
  ondragend?: (dropped: boolean) => void;
}

export const DRAG_THRESHOLD = 4;

export const fileDrag: Action<HTMLElement, FileDragOptions> = (node, initial) => {
  let opts = initial;
  let start: { x: number; y: number; id: number } | null = null;
  let dragging = false;

  function down(e: PointerEvent) {
    if (e.button !== 0 || dragging) return;
    // Buttons inside the source (hover bars) handle their own clicks.
    if ((e.target as HTMLElement).closest('button')) return;
    start = { x: e.clientX, y: e.clientY, id: e.pointerId };
  }

  function move(e: PointerEvent) {
    if (!start || dragging || e.pointerId !== start.id) return;
    if (Math.hypot(e.clientX - start.x, e.clientY - start.y) <= DRAG_THRESHOLD) return;
    dragging = true;
    start = null;
    opts.ondragstart?.();
    // The OLE drag loop owns the mouse until the drop; pointerup may never reach the page.
    api
      .startDrag(opts.path)
      .then((r) => opts.ondragend?.(r.dropped))
      .catch((err) => {
        console.error('start_drag failed', err);
        opts.ondragend?.(false);
      })
      .finally(() => (dragging = false));
  }

  function up(e: PointerEvent) {
    if (start && e.pointerId === start.id && !dragging) opts.onclick?.();
    start = null;
  }

  function cancel() {
    start = null;
  }

  node.addEventListener('pointerdown', down);
  window.addEventListener('pointermove', move);
  node.addEventListener('pointerup', up);
  window.addEventListener('pointercancel', cancel);
  window.addEventListener('blur', cancel);

  return {
    update(next) {
      opts = next;
    },
    destroy() {
      node.removeEventListener('pointerdown', down);
      window.removeEventListener('pointermove', move);
      node.removeEventListener('pointerup', up);
      window.removeEventListener('pointercancel', cancel);
      window.removeEventListener('blur', cancel);
    },
  };
};
