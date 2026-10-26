// Dates and sizes as the library shows them.

export interface DayGroup<T> {
  title: string;
  items: T[];
}

const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate());

/** "Today", "Yesterday", "Monday 19 October" this year, "19 October 2025" before. */
export function dayTitle(day: Date, now: Date): string {
  const d = startOfDay(day);
  const today = startOfDay(now);
  if (d.getTime() === today.getTime()) return 'Today';
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);
  if (d.getTime() === yesterday.getTime()) return 'Yesterday';
  if (d.getFullYear() === now.getFullYear()) {
    return d.toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' }).replace(',', '');
  }
  return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });
}

/** Groups items (already sorted newest first) by local calendar day, keeping order. */
export function groupByDay<T>(items: T[], date: (item: T) => number, now: Date): DayGroup<T>[] {
  const groups: DayGroup<T>[] = [];
  let lastKey = -1;
  for (const item of items) {
    const day = startOfDay(new Date(date(item)));
    const key = day.getTime();
    if (key !== lastKey) {
      groups.push({ title: dayTitle(day, now), items: [] });
      lastKey = key;
    }
    groups[groups.length - 1].items.push(item);
  }
  return groups;
}

/** Time of day in the user's locale ("14:03" or "2:03 PM"). */
export function timeOfDay(ms: number): string {
  return new Date(ms).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

export const pixelSize = (w: number, h: number) => `${Math.round(w)} × ${Math.round(h)}`;

/** File name with extension from a Windows or POSIX path. */
export const baseName = (path: string) => path.split(/[\\/]/).pop() ?? path;
