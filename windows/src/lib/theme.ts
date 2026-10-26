// Light/dark from the appearance setting (or the system) and the Windows accent colour.
import { isLight } from './editor/model';
import type { Appearance } from './types';

const media = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null;
let appearance: Appearance = 'system';

function apply() {
  const dark = appearance === 'dark' || (appearance === 'system' && !!media?.matches);
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
}

media?.addEventListener('change', apply);

export function setAppearance(a: Appearance): void {
  appearance = a;
  apply();
}

export function setAccent(hex: string): void {
  if (!/^#[0-9a-fA-F]{6}$/.test(hex)) return;
  const style = document.documentElement.style;
  style.setProperty('--accent', hex);
  style.setProperty('--accent-ink', isLight(hex) ? '#000000' : '#ffffff');
}

/** Resolved accent for canvas drawing (selection handles). */
export function accentColor(): string {
  return getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#0067c0';
}

/** Whether chrome animations should run. */
export function reduceMotion(): boolean {
  return typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
}

apply();
