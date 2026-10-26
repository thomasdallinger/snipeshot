import { describe, expect, it } from 'vitest';
import { dayTitle, groupByDay, pixelSize } from './format';

// Local time throughout: grouping follows the user's calendar day.
const now = new Date(2026, 9, 21, 14, 3, 22); // Wednesday 21 October 2026

describe('dayTitle', () => {
  it('names recent days', () => {
    expect(dayTitle(new Date(2026, 9, 21, 0, 0, 1), now)).toBe('Today');
    expect(dayTitle(new Date(2026, 9, 20, 23, 59), now)).toBe('Yesterday');
  });

  it('uses weekday, day and month within the year', () => {
    expect(dayTitle(new Date(2026, 9, 19, 9, 0), now)).toBe('Monday 19 October');
    expect(dayTitle(new Date(2026, 0, 1, 9, 0), now)).toBe('Thursday 1 January');
  });

  it('adds the year for older captures', () => {
    expect(dayTitle(new Date(2025, 9, 19, 9, 0), now)).toBe('19 October 2025');
  });

  it('handles yesterday across a month boundary', () => {
    expect(dayTitle(new Date(2026, 9, 31, 22, 0), new Date(2026, 10, 1, 8, 0))).toBe('Yesterday');
  });
});

describe('groupByDay', () => {
  it('groups newest-first items by day and keeps their order', () => {
    const items = [
      { id: 'a', at: new Date(2026, 9, 21, 13, 0).getTime() },
      { id: 'b', at: new Date(2026, 9, 21, 8, 0).getTime() },
      { id: 'c', at: new Date(2026, 9, 20, 18, 0).getTime() },
      { id: 'd', at: new Date(2026, 9, 19, 11, 0).getTime() },
      { id: 'e', at: new Date(2026, 9, 19, 10, 0).getTime() },
      { id: 'f', at: new Date(2025, 4, 2, 10, 0).getTime() },
    ];
    const groups = groupByDay(items, (i) => i.at, now);
    expect(groups.map((g) => g.title)).toEqual(['Today', 'Yesterday', 'Monday 19 October', '2 May 2025']);
    expect(groups.map((g) => g.items.map((i) => i.id))).toEqual([['a', 'b'], ['c'], ['d', 'e'], ['f']]);
  });

  it('returns nothing for an empty list', () => {
    expect(groupByDay([], () => 0, now)).toEqual([]);
  });
});

describe('pixelSize', () => {
  it('rounds and uses a multiplication sign', () => {
    expect(pixelSize(1440, 879.6)).toBe('1440 × 880');
  });
});
