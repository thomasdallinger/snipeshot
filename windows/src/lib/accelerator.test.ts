import { describe, expect, it } from 'vitest';
import { formatAccelerator, keyName, recordKey, usesPrintScreen, type KeyLike } from './accelerator';

function key(code: string, init: Partial<KeyLike> = {}): KeyLike {
  return {
    type: 'keydown',
    key: code.replace(/^Key|^Digit/, ''),
    code,
    ctrlKey: false,
    altKey: false,
    shiftKey: false,
    metaKey: false,
    ...init,
  };
}

describe('recordKey', () => {
  it('records modifier combinations in Ctrl, Alt, Shift, Super order', () => {
    expect(recordKey(key('Digit4', { ctrlKey: true, shiftKey: true }))).toEqual({ kind: 'set', accelerator: 'Ctrl+Shift+4' });
    expect(recordKey(key('KeyS', { ctrlKey: true, altKey: true }))).toEqual({ kind: 'set', accelerator: 'Ctrl+Alt+S' });
    expect(recordKey(key('KeyS', { metaKey: true, shiftKey: true }))).toEqual({ kind: 'set', accelerator: 'Shift+Super+S' });
  });

  it('accepts Print Screen on key-up, where Windows delivers it, and on key-down', () => {
    expect(recordKey(key('PrintScreen', { type: 'keyup', key: 'PrintScreen' }))).toEqual({ kind: 'set', accelerator: 'PrintScreen' });
    expect(recordKey(key('PrintScreen', { key: 'PrintScreen' }))).toEqual({ kind: 'set', accelerator: 'PrintScreen' });
    expect(recordKey(key('PrintScreen', { type: 'keyup', key: 'PrintScreen', altKey: true }))).toEqual({
      kind: 'set',
      accelerator: 'Alt+PrintScreen',
    });
  });

  it('allows function keys without modifiers', () => {
    expect(recordKey(key('F9', { key: 'F9' }))).toEqual({ kind: 'set', accelerator: 'F9' });
    expect(recordKey(key('F24', { key: 'F24' }))).toEqual({ kind: 'set', accelerator: 'F24' });
  });

  it('rejects keys that would swallow normal typing', () => {
    expect(recordKey(key('KeyA'))).toEqual({ kind: 'invalid' });
    expect(recordKey(key('KeyA', { shiftKey: true }))).toEqual({ kind: 'invalid' });
    expect(recordKey(key('Digit4', { shiftKey: true }))).toEqual({ kind: 'invalid' });
    expect(recordKey(key('IntlBackslash', { ctrlKey: true }))).toEqual({ kind: 'invalid' });
  });

  it('cancels on Esc and clears on Delete or Backspace', () => {
    expect(recordKey(key('Escape', { key: 'Escape' }))).toEqual({ kind: 'cancel' });
    expect(recordKey(key('Delete', { key: 'Delete' }))).toEqual({ kind: 'clear' });
    expect(recordKey(key('Backspace', { key: 'Backspace' }))).toEqual({ kind: 'clear' });
  });

  it('keeps listening for modifiers alone and for other key-ups', () => {
    expect(recordKey(key('ShiftLeft', { key: 'Shift', shiftKey: true }))).toEqual({ kind: 'ignore' });
    expect(recordKey(key('ControlRight', { key: 'Control', ctrlKey: true }))).toEqual({ kind: 'ignore' });
    expect(recordKey(key('MetaLeft', { key: 'Meta', metaKey: true }))).toEqual({ kind: 'ignore' });
    expect(recordKey(key('KeyA', { type: 'keyup', ctrlKey: true }))).toEqual({ kind: 'ignore' });
  });
});

describe('keyName', () => {
  it('maps physical keys to accelerator names', () => {
    expect(keyName('KeyZ')).toBe('Z');
    expect(keyName('Digit0')).toBe('0');
    expect(keyName('Numpad7')).toBe('Numpad7');
    expect(keyName('F12')).toBe('F12');
    expect(keyName('F25')).toBeNull();
    expect(keyName('Minus')).toBe('Minus');
  });
});

describe('formatAccelerator', () => {
  it('writes shortcuts the Windows way', () => {
    expect(formatAccelerator('Ctrl+Shift+4')).toBe('Ctrl+Shift+4');
    expect(formatAccelerator('Alt+PrintScreen')).toBe('Alt+Print Screen');
    expect(formatAccelerator('Shift+Super+S')).toBe('Shift+Win+S');
    expect(formatAccelerator('Ctrl+Minus')).toBe('Ctrl+-');
    expect(formatAccelerator('Ctrl+Numpad4')).toBe('Ctrl+Num 4');
  });
});

describe('usesPrintScreen', () => {
  it('spots the Print Screen key in any combination', () => {
    expect(usesPrintScreen('PrintScreen')).toBe(true);
    expect(usesPrintScreen('Ctrl+PrintScreen')).toBe(true);
    expect(usesPrintScreen('Ctrl+Shift+4')).toBe(false);
    expect(usesPrintScreen(null)).toBe(false);
  });
});
