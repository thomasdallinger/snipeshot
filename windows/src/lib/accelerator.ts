// Shortcut recording: keyboard events to Tauri accelerator strings ("Ctrl+Shift+4", "Alt+PrintScreen").
// Port of KeyCombo.swift's rules for Windows.

export interface KeyLike {
  type: string;
  key: string;
  code: string;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  metaKey: boolean;
}

export type RecordResult =
  | { kind: 'set'; accelerator: string }
  | { kind: 'clear' }
  | { kind: 'cancel' }
  /** Keep listening (a modifier on its own, a key-up). */
  | { kind: 'ignore' }
  /** Not usable as a global shortcut; tell the user and keep listening. */
  | { kind: 'invalid' };

const NAMED: Record<string, string> = {
  Space: 'Space',
  Enter: 'Enter',
  Tab: 'Tab',
  Insert: 'Insert',
  Home: 'Home',
  End: 'End',
  PageUp: 'PageUp',
  PageDown: 'PageDown',
  ArrowUp: 'ArrowUp',
  ArrowDown: 'ArrowDown',
  ArrowLeft: 'ArrowLeft',
  ArrowRight: 'ArrowRight',
  Minus: 'Minus',
  Equal: 'Equal',
  BracketLeft: 'BracketLeft',
  BracketRight: 'BracketRight',
  Backslash: 'Backslash',
  Semicolon: 'Semicolon',
  Quote: 'Quote',
  Comma: 'Comma',
  Period: 'Period',
  Slash: 'Slash',
  Backquote: 'Backquote',
  PrintScreen: 'PrintScreen',
  Pause: 'Pause',
  ScrollLock: 'ScrollLock',
  NumpadAdd: 'NumpadAdd',
  NumpadSubtract: 'NumpadSubtract',
  NumpadMultiply: 'NumpadMultiply',
  NumpadDivide: 'NumpadDivide',
  NumpadDecimal: 'NumpadDecimal',
};

const MODIFIER_CODES = /^(Control|Alt|Shift|Meta|OS)(Left|Right)?$/;

/** Accelerator key name for a physical key, or null when it cannot be a shortcut key. */
export function keyName(code: string): string | null {
  let m: RegExpMatchArray | null;
  if ((m = code.match(/^Key([A-Z])$/))) return m[1];
  if ((m = code.match(/^Digit([0-9])$/))) return m[1];
  if ((m = code.match(/^Numpad([0-9])$/))) return `Numpad${m[1]}`;
  if ((m = code.match(/^F([1-9]|1[0-9]|2[0-4])$/))) return `F${m[1]}`;
  return NAMED[code] ?? null;
}

const isFunctionKey = (name: string) => /^F([1-9]|1[0-9]|2[0-4])$/.test(name);

/**
 * Turns one key event into a recorder decision. Windows delivers PrintScreen only on key-up, so that key
 * is accepted on either; everything else on key-down. Like macOS, a global shortcut needs Ctrl, Alt or Win
 * (otherwise it would swallow normal typing), except PrintScreen and F1–F24.
 */
export function recordKey(e: KeyLike): RecordResult {
  const isPrint = e.code === 'PrintScreen' || e.key === 'PrintScreen';
  if (e.type === 'keyup' && !isPrint) return { kind: 'ignore' };
  if (e.type !== 'keydown' && e.type !== 'keyup') return { kind: 'ignore' };
  if (MODIFIER_CODES.test(e.code) || ['Control', 'Alt', 'Shift', 'Meta', 'OS'].includes(e.key)) return { kind: 'ignore' };

  const anyModifier = e.ctrlKey || e.altKey || e.shiftKey || e.metaKey;
  if (e.key === 'Escape' && !anyModifier) return { kind: 'cancel' };
  if ((e.key === 'Delete' || e.key === 'Backspace') && !anyModifier) return { kind: 'clear' };

  const name = isPrint ? 'PrintScreen' : keyName(e.code);
  if (!name) return { kind: 'invalid' };
  if (!(e.ctrlKey || e.altKey || e.metaKey) && name !== 'PrintScreen' && !isFunctionKey(name)) return { kind: 'invalid' };

  const parts: string[] = [];
  if (e.ctrlKey) parts.push('Ctrl');
  if (e.altKey) parts.push('Alt');
  if (e.shiftKey) parts.push('Shift');
  if (e.metaKey) parts.push('Super');
  parts.push(name);
  return { kind: 'set', accelerator: parts.join('+') };
}

const DISPLAY: Record<string, string> = {
  Super: 'Win',
  Meta: 'Win',
  CommandOrControl: 'Ctrl',
  CmdOrCtrl: 'Ctrl',
  Control: 'Ctrl',
  Option: 'Alt',
  PrintScreen: 'Print Screen',
  ArrowUp: 'Up',
  ArrowDown: 'Down',
  ArrowLeft: 'Left',
  ArrowRight: 'Right',
  PageUp: 'Page Up',
  PageDown: 'Page Down',
  Minus: '-',
  Equal: '=',
  BracketLeft: '[',
  BracketRight: ']',
  Backslash: '\\',
  Semicolon: ';',
  Quote: "'",
  Comma: ',',
  Period: '.',
  Slash: '/',
  Backquote: '`',
  NumpadAdd: 'Num +',
  NumpadSubtract: 'Num -',
  NumpadMultiply: 'Num *',
  NumpadDivide: 'Num /',
  NumpadDecimal: 'Num .',
};

/** How Windows writes shortcuts: "Ctrl+Shift+4", "Alt+Print Screen", "Win+Shift+S". */
export function formatAccelerator(acc: string): string {
  return acc
    .split('+')
    .filter(Boolean)
    .map((p) => DISPLAY[p] ?? p.replace(/^Numpad([0-9])$/, 'Num $1'))
    .join('+');
}

/** Whether the accelerator involves the Print Screen key (affected by the Snipping Tool setting). */
export const usesPrintScreen = (acc: string | null | undefined) => !!acc && acc.split('+').includes('PrintScreen');
