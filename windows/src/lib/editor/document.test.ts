import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MarkupDocument, SAVE_DELAY_MS, UNDO_LIMIT } from './document.svelte';
import { makeAnnotation, type EditFile } from './model';

function makeDoc(save = vi.fn(async (_file: EditFile) => {})) {
  const doc = new MarkupDocument({ path: 'C:\\a.png', pointSize: { w: 400, h: 300 }, scale: 2, edits: null, save });
  return { doc, save };
}

const rect = (x = 10) => makeAnnotation('rectangle', { frame: { x, y: 10, w: 50, h: 40 } });

describe('undo and redo', () => {
  it('restores the state before each registered change', () => {
    const { doc } = makeDoc();
    expect(doc.canUndo).toBe(false);
    doc.registerUndo();
    doc.add(rect());
    doc.registerUndo();
    doc.crop = { x: 0, y: 0, w: 100, h: 100 };
    expect(doc.canUndo).toBe(true);

    doc.undo();
    expect(doc.crop).toBeNull();
    expect(doc.annotations).toHaveLength(1);
    expect(doc.canRedo).toBe(true);
    doc.undo();
    expect(doc.annotations).toHaveLength(0);
    expect(doc.canUndo).toBe(false);

    doc.redo();
    doc.redo();
    expect(doc.annotations).toHaveLength(1);
    expect(doc.crop).toEqual({ x: 0, y: 0, w: 100, h: 100 });
    expect(doc.canRedo).toBe(false);
  });

  it('a new change drops the redo stack', () => {
    const { doc } = makeDoc();
    doc.registerUndo();
    doc.add(rect());
    doc.undo();
    expect(doc.canRedo).toBe(true);
    doc.registerUndo();
    doc.add(rect(20));
    expect(doc.canRedo).toBe(false);
  });

  it(`keeps at most ${UNDO_LIMIT} steps`, () => {
    const { doc } = makeDoc();
    for (let i = 0; i < UNDO_LIMIT + 50; i++) {
      doc.registerUndo();
      doc.add(rect(i));
    }
    let steps = 0;
    while (doc.canUndo) {
      doc.undo();
      steps++;
    }
    expect(steps).toBe(UNDO_LIMIT);
    expect(doc.annotations).toHaveLength(50);
  });

  it('edits never leak into earlier snapshots', () => {
    const { doc } = makeDoc();
    const a = rect();
    doc.add(a);
    doc.registerUndo();
    doc.update(a.id, (x) => (x.frame.x = 99));
    doc.offset(a.id, 1, 1);
    expect(doc.find(a.id)!.frame.x).toBe(100);
    doc.undo();
    expect(doc.find(a.id)!.frame.x).toBe(10);
    expect(a.frame.x).toBe(10);
  });

  it('clears the selection when undo removes the selected annotation', () => {
    const { doc } = makeDoc();
    doc.registerUndo();
    const a = rect();
    doc.add(a);
    doc.selectionId = a.id;
    doc.undo();
    expect(doc.selectionId).toBeNull();
  });

  it('duplicates with an offset and the next step number', () => {
    const { doc } = makeDoc();
    const s = makeAnnotation('step', { frame: { x: 0, y: 0, w: 28, h: 28 }, step: 1 });
    doc.add(s);
    doc.duplicate(s.id);
    const copy = doc.selectedItem!;
    expect(copy.id).not.toBe(s.id);
    expect(copy.frame).toMatchObject({ x: 16, y: 16 });
    expect(copy.step).toBe(2);
    expect(doc.nextStep).toBe(3);
  });

  it('reorders with front and back', () => {
    const { doc } = makeDoc();
    const [a, b, c] = [rect(1), rect(2), rect(3)];
    [a, b, c].forEach((x) => doc.add(x));
    doc.bringToFront(a.id);
    expect(doc.annotations.map((x) => x.id)).toEqual([b.id, c.id, a.id]);
    doc.sendToBack(a.id);
    expect(doc.annotations.map((x) => x.id)).toEqual([a.id, b.id, c.id]);
  });
});

describe('saving', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it(`debounces saves by ${SAVE_DELAY_MS} ms`, async () => {
    const { doc, save } = makeDoc();
    doc.add(rect());
    doc.didChange();
    expect(doc.isSaved).toBe(false);
    await vi.advanceTimersByTimeAsync(SAVE_DELAY_MS - 50);
    doc.didChange();
    await vi.advanceTimersByTimeAsync(SAVE_DELAY_MS - 50);
    expect(save).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(100);
    expect(save).toHaveBeenCalledTimes(1);
    expect(save.mock.calls[0][0].annotations).toHaveLength(1);
    expect(save.mock.calls[0][0].scale).toBe(2);
    expect(doc.isSaved).toBe(true);
  });

  it('flush writes a pending change right away', async () => {
    const { doc, save } = makeDoc();
    doc.didChange();
    await doc.flush();
    expect(save).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(SAVE_DELAY_MS * 2);
    expect(save).toHaveBeenCalledTimes(1);
  });

  it('undo also saves', async () => {
    const { doc, save } = makeDoc();
    doc.registerUndo();
    doc.add(rect());
    doc.undo();
    await vi.advanceTimersByTimeAsync(SAVE_DELAY_MS);
    expect(save).toHaveBeenCalledTimes(1);
    expect(save.mock.calls[0][0].annotations).toHaveLength(0);
  });
});
