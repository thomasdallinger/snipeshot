# Snipeshot for Windows: backend ↔ frontend contract

The Windows app is Tauri 2 (Rust, `windows/src-tauri`) + Svelte 5 (`windows/src`). It mirrors the macOS app in
`Sources/Snipeshot` feature for feature. This file is the single source of truth for the IPC surface; change it
here first when the surface changes.

## Who does what

- **Rust** owns everything that touches the OS: screen capture, the frozen-screen selector (a native Win32
  window, not a webview), global shortcuts, tray icon and menu, files and folders, clipboard, file drag-out
  (OLE), the recycle bin, the capture sound, window placement (shelf, pins), autostart and settings storage.
- **Svelte** owns all webview UI: library + editor, settings, the shelf cards and pinned images. It also owns
  the **only renderer** of edits (`renderer.ts`, Canvas 2D). Rust never draws annotations: the frontend
  uploads a flattened PNG whenever edits change (see `write_flattened`), and Rust uses that file for copy,
  drag, export, previews and pins.

## Windows (Tauri labels)

All webviews load the same bundle; the hash route picks the view.

| Label | Route | Shape |
|---|---|---|
| `library` | `#/library` | normal window, 1100×720, min 820×520, hidden until opened, hides instead of closing |
| `settings` | `#/settings` | normal window, 560×520, not resizable, hidden until opened, hides instead of closing |
| `shelf` | `#/shelf` | borderless, transparent, always on top, skip taskbar, never takes focus (`WS_EX_NOACTIVATE`), sized and placed by Rust |
| `pin-<n>` | `#/pin?path=<uri-encoded path>&scale=<n>` | borderless, transparent, always on top, skip taskbar, resizable; Rust sizes it to the image in points (max 60% of the work area), centred on the monitor under the cursor |

The selector overlay is native (one topmost Win32 window per monitor, per-monitor DPI aware).

## Files and formats (same as macOS)

- Default save folder: `%USERPROFILE%\Pictures\Snipeshot`. Capture names: `Capture 2026-10-21 14.03.22.png`,
  then `Capture … (2).png` on collision.
- PNG captures carry a `pHYs` chunk with `96 × scale` DPI; `scale` = the monitor's DPI scale (1, 1.25, 1.5, 2…).
  When reading, `scale = dpi / 96` (fallback 1).
- Edit file: `.<file name>.snipeshot.json` next to the image, with the Windows *hidden* attribute set. The JSON is
  byte-compatible with the macOS format documented in `docs/DEVELOPMENT.md` (coordinates in image points, origin
  top-left, `scale` = pixels per point). No edits → the file is deleted.
- Flattened cache: `%LOCALAPPDATA%\io.github.thomasdallinger.snipeshot\Flattened\<sha1 of path>.png`, written by
  `write_flattened`. It is **fresh** when it exists and is not older than the edit file. Rust uses
  `flattened_or_original(path)` = fresh cache if the edit file exists, else the original.
- Settings: `%APPDATA%\io.github.thomasdallinger.snipeshot\settings.json` (Tauri `app_config_dir`).

## Types (serde `camelCase`; mirrored in `windows/src/lib/types.ts`)

```ts
type CaptureKind = 'area' | 'window' | 'screen';
type FileFormat = 'png' | 'jpeg';
type Appearance = 'system' | 'light' | 'dark';

/** Tauri accelerator syntax: "PrintScreen", "Alt+PrintScreen", "Ctrl+Shift+4", "Ctrl+Alt+S", "F9". */
type Accelerator = string;

interface Settings {
  saveFolder: string;
  fileFormat: FileFormat;          // default 'png'
  jpegQuality: number;             // 0..1, default 0.9
  showShelf: boolean;              // default true
  copyAfterCapture: boolean;       // default true
  editAfterCapture: boolean;       // default false
  captureSound: boolean;           // default true
  closeShelfItemAfterDrag: boolean;// default true
  appearance: Appearance;          // default 'system'
  openAtLogin: boolean;            // backed by the autostart plugin, not the JSON file
  shortcuts: Record<CaptureKind, Accelerator | null>; // null = cleared on purpose
  didShowWelcome: boolean;
}
// Default shortcuts: area "PrintScreen", window "Alt+PrintScreen", screen "Ctrl+PrintScreen".

interface CaptureFile {
  path: string;          // absolute
  name: string;          // file name without extension
  createdAt: number;     // ms since epoch
  modifiedAt: number;    // ms, max(image mtime, edit-file mtime): use as cache buster
  width: number;         // pixels
  height: number;
  scale: number;         // pixels per point (edit file's scale if present, else from DPI)
  hasEdits: boolean;
  previewPath: string;   // flattened cache when fresh, else the original
  flattenedStale: boolean; // hasEdits but no fresh cache: the frontend should re-render and upload
}

interface ShelfItem { path: string; width: number; height: number; previewPath: string; modifiedAt: number }

interface ShortcutStatus {
  blocked: CaptureKind[];            // RegisterHotKey failed (another app owns the keys)
  printScreenOpensSnippingTool: boolean; // HKCU\Control Panel\Keyboard\PrintScreenKeyForSnippingEnabled == 1
}

interface SystemInfo { accentColor: string /* #RRGGBB */; version: string }
```

Images are shown with `convertFileSrc(path)` (asset protocol enabled for all local paths) plus
`?v=<modifiedAt>` as a cache buster.

## Commands (`invoke`)

Errors are returned as `string` messages.

| Command | Args | Returns | Notes |
|---|---|---|---|
| `get_settings` | – | `Settings` | |
| `set_settings` | `{ patch: Partial<Settings> }` | `Settings` | persists, re-registers shortcuts, toggles autostart, emits `settings-changed` |
| `reset_shortcuts` | – | `Settings` | |
| `shortcut_status` | – | `ShortcutStatus` | settings polls this every 1.5 s while open |
| `set_print_screen_opens_snipping_tool` | `{ enabled: boolean }` | `ShortcutStatus` | writes the registry value, re-registers shortcuts |
| `pause_shortcuts` / `resume_shortcuts` | – | – | while the shortcut recorder listens |
| `system_info` | – | `SystemInfo` | |
| `capture` | `{ kind: CaptureKind }` | – | same as the shortcut; returns immediately |
| `list_captures` | – | `CaptureFile[]` | newest first, images only (png jpg jpeg gif bmp tif tiff webp), hidden files skipped |
| `read_edits` | `{ path }` | `EditFile \| null` | raw JSON object in the macOS format |
| `write_edits` | `{ path, edits: EditFile \| null }` | – | null or no edits → delete edit file and cache; sets hidden attribute; emits `edits-changed` |
| `write_flattened` | raw body = PNG bytes, header `x-path` = `encodeURIComponent(path)` | – | writes the cache; emits `edits-changed` |
| `copy_capture` | `{ path }` | – | `flattened_or_original` to the clipboard (CF_DIB + registered "PNG") |
| `copy_png` | raw body = PNG bytes | – | for the pin's copy and anything already rendered |
| `export_capture` | `{ path }` | `string \| null` | save dialog (PNG), suggested name = capture name; returns the written path |
| `show_in_explorer` | `{ path }` | – | `explorer /select,` |
| `open_save_folder` | – | – | |
| `choose_save_folder` | – | `string \| null` | folder picker; does **not** change settings by itself |
| `delete_capture` | `{ path }` | – | recycle bin; removes edit file and cache; removes it from the shelf; emits `library-changed` |
| `import_files` | `{ paths: string[] }` | `string[]` | copies images into the save folder |
| `open_library` | `{ path?: string }` | – | shows and focuses `library`; emits `open-capture` to it when `path` is set |
| `open_settings` | `{ tab?: 'general' \| 'shortcuts' \| 'saving' }` | – | emits `open-settings-tab` to `settings` |
| `pin_capture` | `{ path }` | – | opens a `pin-<n>` window with `flattened_or_original(path)` |
| `pin_clipboard` | – | – | clipboard image → temp PNG → pin; message beep when there is none |
| `shelf_items` | – | `ShelfItem[]` | oldest first (top to bottom) |
| `shelf_remove` | `{ path }` | – | |
| `shelf_set_hover` | `{ hovering: boolean }` | – | while true Rust does not move the shelf between monitors |
| `start_drag` | `{ path }` | `{ dropped: boolean }` | OLE file drag of `flattened_or_original(path)` from the calling window; resolves when the drag ends. When the setting says so and it was dropped, Rust removes the shelf item itself |
| `close_window` | – | – | closes (pins) or hides (library, settings) the calling window |

## Events (`listen`)

| Event | Payload | To |
|---|---|---|
| `settings-changed` | `Settings` | all |
| `library-changed` | – | all (folder watcher, debounced 250 ms; also after saves, deletes, imports) |
| `edits-changed` | `{ path }` | all |
| `shelf-changed` | `ShelfItem[]` | `shelf` |
| `shelf-copied` | `{ path }` | `shelf` (show the "Copied" state for 1.2 s) |
| `open-capture` | `{ path }` | `library` |
| `open-settings-tab` | `{ tab }` | `settings` |

## Behaviour that must match macOS

- After a capture: save → copy (setting) → sound (setting) → shelf (setting) → editor (setting).
- **Shelf placement:** bottom-left of the work area of the monitor the capture was taken on, 16 px margin,
  cards 200 px wide, card height `clamp(200 × h / w, 72, 150)`, 10 px apart, newest at the bottom, at most 5.
  The window has 18 px of transparent room on every side for card shadows. **It follows the cursor:** while
  the shelf is visible Rust checks the cursor every 250 ms; when it is on a different monitor and no mouse
  button is held and `shelf_set_hover` is false, the shelf moves to the bottom-left of that monitor.
- Capture sound: `assets/sounds/capture.wav` at the repository root, embedded with `include_bytes!` and
  played with `PlaySoundW(SND_MEMORY | SND_ASYNC)`. The macOS app plays the same file.
