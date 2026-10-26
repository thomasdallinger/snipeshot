// Hash routes, one per window label (docs/ipc.md).
import type { SettingsTab } from './types';

export type Route =
  | { view: 'library' }
  | { view: 'settings'; tab: SettingsTab | null }
  | { view: 'shelf' }
  | { view: 'pin'; path: string; scale: number };

const TABS: SettingsTab[] = ['general', 'shortcuts', 'saving'];

export function parseRoute(hash: string): Route {
  const raw = hash.replace(/^#\/?/, '');
  const [name, query = ''] = raw.split('?');
  const q = new URLSearchParams(query);
  switch (name) {
    case 'settings': {
      const tab = q.get('tab') as SettingsTab | null;
      return { view: 'settings', tab: tab && TABS.includes(tab) ? tab : null };
    }
    case 'shelf':
      return { view: 'shelf' };
    case 'pin': {
      const scale = Number(q.get('scale'));
      return { view: 'pin', path: q.get('path') ?? '', scale: Number.isFinite(scale) && scale > 0 ? scale : 1 };
    }
    default:
      return { view: 'library' };
  }
}
