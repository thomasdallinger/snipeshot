// Typed wrapper around the Tauri IPC surface described in docs/ipc.md.
// Falls back to an in-memory mock backend when running in a plain browser (`npm run dev`).
import { convertFileSrc, invoke } from '@tauri-apps/api/core';
import { PhysicalPosition, PhysicalSize } from '@tauri-apps/api/dpi';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { mockFileUrl } from './mockFiles';
import type {
  CaptureFile,
  CaptureKind,
  DragResult,
  EditFileJSON,
  EventMap,
  EventName,
  Settings,
  SettingsTab,
  ShelfItem,
  ShortcutStatus,
  SystemInfo,
} from './types';

export const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

export type Unlisten = () => void;

type MockModule = typeof import('./mock');
let mockPromise: Promise<MockModule> | null = null;
/** The mock backend is loaded on demand so it never ships in the Tauri bundle's startup path. */
function mock(): Promise<MockModule> {
  mockPromise ??= import('./mock');
  return mockPromise;
}

/** Resolves once the backend can answer (loads the mock in a browser). */
export async function backendReady(): Promise<void> {
  if (!isTauri) await mock();
}

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (isTauri) return invoke<T>(cmd, args);
  const m = await mock();
  return m.mockInvoke(cmd, args ?? {}) as Promise<T>;
}

/** Commands that take raw bytes as the request body (see `write_flattened` in ipc.md). */
async function callRaw<T>(cmd: string, body: Uint8Array, headers: Record<string, string> = {}): Promise<T> {
  if (isTauri) return invoke<T>(cmd, body, { headers });
  const m = await mock();
  return m.mockInvokeRaw(cmd, body, headers) as Promise<T>;
}

/** Subscribe to a backend event. Resolves to an unlisten function. */
export async function on<E extends EventName>(event: E, handler: (payload: EventMap[E]) => void): Promise<Unlisten> {
  if (isTauri) return listen<EventMap[E]>(event, (e) => handler(e.payload));
  const m = await mock();
  return m.mockListen(event, handler);
}

/** URL for a local image, with `modifiedAt` as cache buster. */
export function fileSrc(path: string, version?: number): string {
  const base = isTauri ? convertFileSrc(path) : (mockFileUrl(path) ?? '');
  if (version === undefined || base.startsWith('blob:') || base.startsWith('data:')) return base;
  return `${base}${base.includes('?') ? '&' : '?'}v=${version}`;
}

export const api = {
  getSettings: () => call<Settings>('get_settings'),
  setSettings: (patch: Partial<Settings>) => call<Settings>('set_settings', { patch }),
  resetShortcuts: () => call<Settings>('reset_shortcuts'),
  shortcutStatus: () => call<ShortcutStatus>('shortcut_status'),
  setPrintScreenOpensSnippingTool: (enabled: boolean) =>
    call<ShortcutStatus>('set_print_screen_opens_snipping_tool', { enabled }),
  /** While the shortcut recorder listens, so the keys reach the webview. */
  pauseShortcuts: () => call<void>('pause_shortcuts'),
  resumeShortcuts: () => call<void>('resume_shortcuts'),
  systemInfo: () => call<SystemInfo>('system_info'),

  capture: (kind: CaptureKind) => call<void>('capture', { kind }),
  listCaptures: () => call<CaptureFile[]>('list_captures'),
  readEdits: (path: string) => call<EditFileJSON | null>('read_edits', { path }),
  writeEdits: (path: string, edits: EditFileJSON | null) => call<void>('write_edits', { path, edits }),
  /** Uploads the flattened PNG for a capture; Rust caches it for copy, drag, export, previews and pins. */
  writeFlattened: (path: string, png: Uint8Array) =>
    callRaw<void>('write_flattened', png, { 'x-path': encodeURIComponent(path) }),
  copyCapture: (path: string) => call<void>('copy_capture', { path }),
  copyPng: (png: Uint8Array) => callRaw<void>('copy_png', png),
  /** Save dialog; resolves to the written path, or null when cancelled. */
  exportCapture: (path: string) => call<string | null>('export_capture', { path }),
  showInExplorer: (path: string) => call<void>('show_in_explorer', { path }),
  openSaveFolder: () => call<void>('open_save_folder'),
  /** Folder picker; does not change settings by itself. */
  chooseSaveFolder: () => call<string | null>('choose_save_folder'),
  deleteCapture: (path: string) => call<void>('delete_capture', { path }),
  importFiles: (paths: string[]) => call<string[]>('import_files', { paths }),

  openLibrary: (path?: string) => call<void>('open_library', { path }),
  openSettings: (tab?: SettingsTab) => call<void>('open_settings', { tab }),
  pinCapture: (path: string) => call<void>('pin_capture', { path }),
  pinClipboard: () => call<void>('pin_clipboard'),

  shelfItems: () => call<ShelfItem[]>('shelf_items'),
  shelfRemove: (path: string) => call<void>('shelf_remove', { path }),
  shelfSetHover: (hovering: boolean) => call<void>('shelf_set_hover', { hovering }),
  /** OLE file drag from the calling window; resolves when the drag ends. */
  startDrag: (path: string) => call<DragResult>('start_drag', { path }),
  /** Closes (pins) or hides (library, settings) the calling window. */
  closeWindow: () => call<void>('close_window'),
};

// ---------------------------------------------------------------- window helpers

/** Begin a native window move (pins). No-op in the browser. */
export async function startWindowDrag(): Promise<void> {
  if (!isTauri) return;
  await getCurrentWindow().startDragging();
}

/** Resizes the calling window to `width` × `height` logical px, keeping its centre where it is. */
export async function resizeWindowCentered(width: number, height: number): Promise<void> {
  if (!isTauri) return;
  const w = getCurrentWindow();
  const [pos, size, factor] = await Promise.all([w.outerPosition(), w.outerSize(), w.scaleFactor()]);
  const nw = Math.round(width * factor),
    nh = Math.round(height * factor);
  const cx = pos.x + size.width / 2,
    cy = pos.y + size.height / 2;
  await w.setSize(new PhysicalSize(nw, nh));
  await w.setPosition(new PhysicalPosition(Math.round(cx - nw / 2), Math.round(cy - nh / 2)));
}

/** Current inner size of the calling window in logical px. */
export async function windowLogicalSize(): Promise<{ width: number; height: number }> {
  if (!isTauri) return { width: window.innerWidth, height: window.innerHeight };
  const w = getCurrentWindow();
  const [size, factor] = await Promise.all([w.innerSize(), w.scaleFactor()]);
  return { width: size.width / factor, height: size.height / factor };
}

export interface FileDropHandlers {
  /** Files are being dragged over the window (true) or left it (false). */
  hover: (over: boolean) => void;
  drop: (paths: string[]) => void;
}

/**
 * Files dropped from Explorer. Tauri hands over real paths through the webview's drag-drop event;
 * in the browser the mock registers the dropped files under fake paths.
 */
export async function onFileDrop(handlers: FileDropHandlers): Promise<Unlisten> {
  if (isTauri) {
    return getCurrentWebview().onDragDropEvent((e) => {
      const p = e.payload;
      if (p.type === 'enter' || p.type === 'over') handlers.hover(true);
      else if (p.type === 'leave') handlers.hover(false);
      else if (p.type === 'drop') {
        handlers.hover(false);
        if (p.paths.length) handlers.drop(p.paths);
      }
    });
  }
  const m = await mock();
  return m.mockFileDrop(handlers);
}
