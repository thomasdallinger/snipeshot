// Edits → files: the edit file plus the flattened PNG Rust uses for copy, drag, export, previews and pins.
import { api, fileSrc } from '../api';
import type { CaptureFile } from '../types';
import { makeLayout } from './geometry';
import { decodeEditFile, encodeEditFile, hasEdits, type EditFile } from './model';
import { canvasToPng, flattenToCanvas, makeSource, type RenderSource } from './renderer';

/** Loads a local image so it can be drawn into (and exported from) a canvas. */
export function loadImage(path: string, version?: number): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    // The asset protocol answers with CORS headers; without this the canvas could not be exported.
    img.crossOrigin = 'anonymous';
    img.decoding = 'async';
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error(`Could not load ${path}`));
    img.src = fileSrc(path, version);
  });
}

export async function renderFlattened(source: RenderSource, file: EditFile): Promise<Uint8Array> {
  const layout = makeLayout(source.pointSize, file.crop, file.backdrop);
  return canvasToPng(flattenToCanvas(source, layout, file.annotations));
}

/** Writes the edit file (or deletes it when nothing is left) and uploads the flattened image. */
export async function persistEdits(path: string, source: RenderSource, file: EditFile): Promise<void> {
  if (!hasEdits(file)) {
    await api.writeEdits(path, null);
    return;
  }
  await api.writeEdits(path, encodeEditFile(file));
  // After the edit file, so the cache is never older than it (that is what makes it fresh).
  await api.writeFlattened(path, await renderFlattened(source, file));
}

const pending = new Set<string>();
let queue: Promise<void> = Promise.resolve();

/**
 * Re-renders captures whose flattened cache is missing or older than their edits (edited on another
 * machine, or by the macOS app on a shared folder). One at a time, in the background.
 */
export function refreshStale(captures: CaptureFile[], skip: string | null = null): void {
  for (const c of captures) {
    if (!c.flattenedStale || c.path === skip || pending.has(c.path)) continue;
    pending.add(c.path);
    queue = queue
      .then(async () => {
        const json = await api.readEdits(c.path);
        if (!json) return;
        const file = decodeEditFile(json);
        if (!hasEdits(file)) return;
        const img = await loadImage(c.path, c.modifiedAt);
        const source = makeSource(img, c.width, c.height, file.scale || c.scale);
        await api.writeFlattened(c.path, await renderFlattened(source, file));
      })
      .catch((e) => console.warn('Could not refresh the preview of', c.path, e))
      .finally(() => pending.delete(c.path));
  }
}
