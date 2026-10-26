// Shared, live copy of the settings for every view in this window.
import { api, on } from './api';
import { setAccent, setAppearance } from './theme';
import type { Settings } from './types';

export const prefs = $state<{ value: Settings | null; version: string }>({ value: null, version: '' });

let started = false;

/** Loads settings and the accent colour once, then follows `settings-changed`. */
export async function startPrefs(): Promise<void> {
  if (started) return;
  started = true;
  const [s, info] = await Promise.all([api.getSettings(), api.systemInfo().catch(() => null)]);
  prefs.value = s;
  setAppearance(s.appearance);
  if (info) {
    setAccent(info.accentColor);
    prefs.version = info.version;
  }
  await on('settings-changed', (next) => {
    prefs.value = next;
    setAppearance(next.appearance);
  });
}

/** Persists a change and keeps the local copy in step with what Rust stored. */
export async function updatePrefs(patch: Partial<Settings>): Promise<void> {
  if (prefs.value) prefs.value = { ...prefs.value, ...patch };
  prefs.value = await api.setSettings(patch);
}
