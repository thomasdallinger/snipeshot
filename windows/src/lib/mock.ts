// In-memory mock of the Rust backend, used when the UI runs in a plain browser (`npm run dev`).
// It follows docs/ipc.md closely enough that every route renders and every flow can be clicked through.
//
// URL flags (dev only, in the query before the hash): ?empty=1  ?snipping=1  ?blocked=1
//   e.g. http://localhost:1420/?snipping=1#/settings
import type { FileDropHandlers } from './api';
import { registerMockFile } from './mockFiles';
import type {
  CaptureFile,
  CaptureKind,
  EditFileJSON,
  EventMap,
  EventName,
  Settings,
  ShelfItem,
  ShortcutStatus,
} from './types';

type Handler = (payload: never) => void;
const listeners = new Map<string, Set<Handler>>();

function emit<E extends EventName>(event: E, payload: EventMap[E]) {
  // Deliver asynchronously, like real IPC events.
  queueMicrotask(() => {
    for (const h of listeners.get(event) ?? []) (h as (p: EventMap[E]) => void)(payload);
  });
}

export function mockListen<E extends EventName>(event: E, handler: (p: EventMap[E]) => void) {
  let set = listeners.get(event);
  if (!set) listeners.set(event, (set = new Set()));
  set.add(handler as Handler);
  return () => {
    set.delete(handler as Handler);
  };
}

const params = new URLSearchParams(location.search);
const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- data

const FOLDER = 'C:\\Users\\you\\Pictures\\Snipeshot';
const CACHE = 'C:\\Users\\you\\AppData\\Local\\io.github.thomasdallinger.snipeshot\\Flattened';

const settings: Settings = {
  saveFolder: FOLDER,
  fileFormat: 'png',
  jpegQuality: 0.9,
  showShelf: true,
  copyAfterCapture: true,
  editAfterCapture: false,
  captureSound: true,
  closeShelfItemAfterDrag: true,
  appearance: 'system',
  openAtLogin: true,
  shortcuts: { area: 'PrintScreen', window: 'Alt+PrintScreen', screen: 'Ctrl+PrintScreen' },
  didShowWelcome: true,
};
const DEFAULT_SHORTCUTS = clone(settings.shortcuts);

const status: ShortcutStatus = {
  blocked: params.get('blocked') === '1' ? ['window'] : [],
  printScreenOpensSnippingTool: params.get('snipping') === '1',
};

interface MockCapture extends CaptureFile {
  url: string;
}

const SAMPLES = [
  { url: '/mock/sample-dashboard.png', width: 1440, height: 880, scale: 2 },
  { url: '/mock/sample-code.png', width: 960, height: 570, scale: 1.5 },
  { url: '/mock/sample-dialog.png', width: 960, height: 600, scale: 2 },
];

const pad = (n: number) => String(n).padStart(2, '0');
function captureName(d: Date) {
  return `Capture ${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}.${pad(d.getMinutes())}.${pad(d.getSeconds())}`;
}

function makeCapture(sample: (typeof SAMPLES)[number], created: Date, extra: Partial<MockCapture> = {}): MockCapture {
  const name = captureName(created);
  const path = `${FOLDER}\\${name}.png`;
  registerMockFile(path, sample.url);
  return {
    path,
    name,
    createdAt: created.getTime(),
    modifiedAt: created.getTime(),
    width: sample.width,
    height: sample.height,
    scale: sample.scale,
    hasEdits: false,
    previewPath: path,
    flattenedStale: false,
    url: sample.url,
    ...extra,
  };
}

const now = new Date();
const at = (daysAgo: number, h: number, m: number, s = 12) => {
  const d = new Date(now);
  d.setDate(d.getDate() - daysAgo);
  d.setHours(h, m, s, 0);
  // Keep "today" captures in the past even early in the morning.
  return d.getTime() > now.getTime() ? new Date(now.getTime() - 60_000 * (m + 1)) : d;
};

const captures: MockCapture[] =
  params.get('empty') === '1'
    ? []
    : [
        makeCapture(SAMPLES[0], at(0, 9, 14, 3)),
        makeCapture(SAMPLES[1], at(0, 8, 41, 27), { hasEdits: true, flattenedStale: true }),
        makeCapture(SAMPLES[2], at(1, 16, 5, 50)),
        makeCapture(SAMPLES[0], at(5, 11, 32, 8)),
        makeCapture(SAMPLES[2], at(400, 14, 3, 22)),
      ];

/** Edit files by capture path, in the macOS JSON format. */
const edits = new Map<string, EditFileJSON>();
if (captures[1]) {
  edits.set(captures[1].path, {
    format: 1,
    scale: 1.5,
    annotations: [
      {
        id: '8C7A2E4B-3F0D-4C55-9A57-0E5B8F6D1A21',
        type: 'rectangle',
        color: '#E5342E',
        frame: [258, 147, 62, 22],
        stroke: 4,
      },
      {
        id: '1B9E0F5C-77D2-4E0A-8D44-3C6A1F2B9E10',
        type: 'text',
        color: '#E5342E',
        frame: [330, 140, 190, 35],
        text: 'Scale is wrong',
        text_size: 28,
      },
    ],
    backdrop: { enabled: false, preset: 'mist', padding: 48, radius: 10, shadow: true },
  });
}

const shelf: ShelfItem[] = captures.slice(0, 2).reverse().map(toShelfItem);

function toShelfItem(c: MockCapture): ShelfItem {
  return { path: c.path, width: c.width, height: c.height, previewPath: c.previewPath, modifiedAt: c.modifiedAt };
}

function find(path: string): MockCapture {
  const c = captures.find((x) => x.path === path);
  if (!c) throw `No capture at ${path}`;
  return c;
}

function cachePath(path: string) {
  let h = 0;
  for (const ch of path) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return `${CACHE}\\${h.toString(16)}.png`;
}

function touch(c: MockCapture) {
  c.modifiedAt = Date.now();
  const item = shelf.find((s) => s.path === c.path);
  if (item) {
    Object.assign(item, toShelfItem(c));
    emit('shelf-changed', clone(shelf));
  }
}

let shelfHover = false;

// ---------------------------------------------------------------- commands

export async function mockInvoke(cmd: string, args: Record<string, unknown>): Promise<unknown> {
  await sleep(10);
  const path = args.path as string;
  switch (cmd) {
    case 'get_settings':
      return clone(settings);
    case 'set_settings': {
      const patch = args.patch as Partial<Settings>;
      Object.assign(settings, clone(patch));
      emit('settings-changed', clone(settings));
      return clone(settings);
    }
    case 'reset_shortcuts':
      settings.shortcuts = clone(DEFAULT_SHORTCUTS);
      status.blocked = [];
      emit('settings-changed', clone(settings));
      return clone(settings);
    case 'shortcut_status':
      return clone(status);
    case 'set_print_screen_opens_snipping_tool':
      status.printScreenOpensSnippingTool = args.enabled as boolean;
      return clone(status);
    case 'pause_shortcuts':
    case 'resume_shortcuts':
      return;
    case 'system_info':
      return { accentColor: '#0067C0', version: '0.1.0 (browser preview)' };

    case 'capture': {
      // Pretend the selector returned the dashboard sample after a moment.
      const kind = args.kind as CaptureKind;
      await sleep(250);
      const c = makeCapture(SAMPLES[kind === 'window' ? 2 : 0], new Date());
      captures.unshift(c);
      shelf.push(toShelfItem(c));
      if (shelf.length > 5) shelf.splice(0, shelf.length - 5);
      emit('library-changed', null);
      emit('shelf-changed', clone(shelf));
      return;
    }
    case 'list_captures':
      return captures.map(({ url: _url, ...c }) => clone(c));
    case 'read_edits':
      return edits.has(path) ? clone(edits.get(path)!) : null;
    case 'write_edits': {
      const c = find(path);
      const e = args.edits as EditFileJSON | null;
      const any = !!e && ((e.annotations?.length ?? 0) > 0 || !!e.crop || !!e.backdrop?.enabled);
      // Visible in the dev console (and to the browser checks) so the written JSON can be inspected.
      console.debug('[mock] write_edits', JSON.stringify(e));
      if (any) edits.set(path, clone(e!));
      else {
        edits.delete(path);
        c.previewPath = c.path;
      }
      c.hasEdits = any;
      c.flattenedStale = any;
      touch(c);
      emit('edits-changed', { path });
      return;
    }
    case 'copy_capture':
      console.info('[mock] copied', path);
      return;
    case 'export_capture': {
      const c = find(path);
      return `C:\\Users\\you\\Desktop\\${c.name}${c.hasEdits ? ' edited' : ''}.png`;
    }
    case 'show_in_explorer':
    case 'open_save_folder':
      console.info('[mock]', cmd, path ?? settings.saveFolder);
      return;
    case 'choose_save_folder':
      return 'D:\\Screenshots';
    case 'delete_capture': {
      const i = captures.findIndex((c) => c.path === path);
      if (i >= 0) captures.splice(i, 1);
      edits.delete(path);
      removeFromShelf(path);
      emit('library-changed', null);
      return;
    }
    case 'import_files': {
      const added: string[] = [];
      for (const src of args.paths as string[]) {
        const pending = dropped.get(src);
        if (!pending) continue;
        const c = makeCapture({ url: pending.url, width: pending.width, height: pending.height, scale: 1 }, new Date());
        c.name = src.split('\\').pop()!.replace(/\.[^.]+$/, '');
        c.path = `${FOLDER}\\${c.name}.png`;
        registerMockFile(c.path, pending.url);
        c.previewPath = c.path;
        captures.unshift(c);
        added.push(c.path);
      }
      if (added.length) emit('library-changed', null);
      return added;
    }
    case 'open_library':
      if (path) emit('open-capture', { path });
      return;
    case 'open_settings':
      if (args.tab) emit('open-settings-tab', { tab: args.tab as never });
      return;
    case 'pin_capture':
    case 'pin_clipboard':
      console.info('[mock]', cmd, path ?? '');
      return;
    case 'shelf_items':
      return clone(shelf);
    case 'shelf_remove':
      removeFromShelf(path);
      return;
    case 'shelf_set_hover':
      shelfHover = args.hovering as boolean;
      return;
    case 'start_drag': {
      // A real drag blocks until the drop; pretend the user dropped it somewhere.
      await sleep(300);
      if (settings.closeShelfItemAfterDrag) removeFromShelf(path);
      return { dropped: true };
    }
    case 'close_window':
      console.info('[mock] close_window', shelfHover);
      return;
    default:
      throw `Unknown command ${cmd}`;
  }
}

export async function mockInvokeRaw(cmd: string, body: Uint8Array, headers: Record<string, string>): Promise<unknown> {
  await sleep(10);
  switch (cmd) {
    case 'write_flattened': {
      const path = decodeURIComponent(headers['x-path'] ?? '');
      const c = find(path);
      const cache = cachePath(path);
      const url = URL.createObjectURL(new Blob([body as Uint8Array<ArrayBuffer>], { type: 'image/png' }));
      registerMockFile(cache, url);
      c.previewPath = cache;
      c.flattenedStale = false;
      touch(c);
      emit('edits-changed', { path });
      return;
    }
    case 'copy_png':
      console.info('[mock] copied PNG', body.byteLength, 'bytes');
      return;
    default:
      throw `Unknown raw command ${cmd}`;
  }
}

function removeFromShelf(path: string) {
  const i = shelf.findIndex((s) => s.path === path);
  if (i < 0) return;
  shelf.splice(i, 1);
  emit('shelf-changed', clone(shelf));
}

// ---------------------------------------------------------------- file drop

/** Files dropped in the browser, keyed by the fake path the mock hands to `import_files`. */
const dropped = new Map<string, { url: string; width: number; height: number }>();

export function mockFileDrop(handlers: FileDropHandlers): () => void {
  const over = (e: DragEvent) => {
    if (!e.dataTransfer?.types.includes('Files')) return;
    e.preventDefault();
    handlers.hover(true);
  };
  const leave = (e: DragEvent) => {
    if (e.relatedTarget === null) handlers.hover(false);
  };
  const drop = async (e: DragEvent) => {
    e.preventDefault();
    handlers.hover(false);
    const paths: string[] = [];
    for (const file of Array.from(e.dataTransfer?.files ?? [])) {
      if (!file.type.startsWith('image/')) continue;
      const url = URL.createObjectURL(file);
      const bmp = await createImageBitmap(file);
      const p = `C:\\Users\\you\\Downloads\\${file.name}`;
      dropped.set(p, { url, width: bmp.width, height: bmp.height });
      bmp.close();
      paths.push(p);
    }
    if (paths.length) handlers.drop(paths);
  };
  window.addEventListener('dragover', over);
  window.addEventListener('dragleave', leave);
  window.addEventListener('drop', drop);
  return () => {
    window.removeEventListener('dragover', over);
    window.removeEventListener('dragleave', leave);
    window.removeEventListener('drop', drop);
  };
}
