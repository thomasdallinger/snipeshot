// IPC types, mirrored from windows/docs/ipc.md (serde camelCase on the Rust side).

export type CaptureKind = 'area' | 'window' | 'screen';
export type FileFormat = 'png' | 'jpeg';
export type Appearance = 'system' | 'light' | 'dark';
export type SettingsTab = 'general' | 'shortcuts' | 'saving';

/** Tauri accelerator syntax: "PrintScreen", "Alt+PrintScreen", "Ctrl+Shift+4", "Ctrl+Alt+S", "F9". */
export type Accelerator = string;

export interface Settings {
  saveFolder: string;
  fileFormat: FileFormat;
  /** 0..1 */
  jpegQuality: number;
  showShelf: boolean;
  copyAfterCapture: boolean;
  editAfterCapture: boolean;
  captureSound: boolean;
  closeShelfItemAfterDrag: boolean;
  appearance: Appearance;
  /** Backed by the autostart plugin, not the JSON file. */
  openAtLogin: boolean;
  /** null = cleared on purpose. */
  shortcuts: Record<CaptureKind, Accelerator | null>;
  didShowWelcome: boolean;
}

export interface CaptureFile {
  /** Absolute path. */
  path: string;
  /** File name without extension. */
  name: string;
  /** ms since epoch */
  createdAt: number;
  /** ms, max(image mtime, edit-file mtime): use as cache buster */
  modifiedAt: number;
  /** Pixels. */
  width: number;
  height: number;
  /** Pixels per point (edit file's scale if present, else from DPI). */
  scale: number;
  hasEdits: boolean;
  /** Flattened cache when fresh, else the original. */
  previewPath: string;
  /** hasEdits but no fresh cache: the frontend re-renders and uploads it. */
  flattenedStale: boolean;
}

export interface ShelfItem {
  path: string;
  width: number;
  height: number;
  previewPath: string;
  modifiedAt: number;
}

export interface ShortcutStatus {
  /** RegisterHotKey failed (another app owns the keys). */
  blocked: CaptureKind[];
  /** HKCU\Control Panel\Keyboard\PrintScreenKeyForSnippingEnabled == 1 */
  printScreenOpensSnippingTool: boolean;
}

export interface SystemInfo {
  /** #RRGGBB */
  accentColor: string;
  version: string;
}

export interface DragResult {
  dropped: boolean;
}

// ---------------------------------------------------------------- edit file (docs/DEVELOPMENT.md)

/** Raw edit-file JSON as written by the macOS app. Only the fields for the type are present. */
export interface EditFileJSON {
  format?: number;
  scale?: number;
  crop?: number[];
  backdrop?: {
    enabled?: boolean;
    preset?: string;
    color?: string;
    padding?: number;
    radius?: number;
    shadow?: boolean;
  };
  annotations?: AnnotationJSON[];
}

export interface AnnotationJSON {
  id?: string;
  type: string;
  color?: string;
  frame?: number[];
  points?: number[][];
  stroke?: number;
  filled?: boolean;
  text?: string;
  text_size?: number;
  step?: number;
  redaction?: string;
}

// ---------------------------------------------------------------- events

export interface EventMap {
  'settings-changed': Settings;
  'library-changed': null;
  'edits-changed': { path: string };
  'shelf-changed': ShelfItem[];
  'shelf-copied': { path: string };
  'open-capture': { path: string };
  'open-settings-tab': { tab: SettingsTab };
}

export type EventName = keyof EventMap;
