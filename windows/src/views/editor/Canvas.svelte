<script lang="ts">
  import { onMount, tick } from 'svelte';
  import Menu, { type MenuItem } from '../../lib/components/Menu.svelte';
  import {
    canvasSize,
    canvasToDoc,
    clampPoint,
    clampZoom,
    contains,
    docToCanvas,
    docRectToCanvas,
    hitTest,
    isDegenerate,
    rectFrom,
    rectHandles,
    resizeRect,
    snap45,
    type Handle,
  } from '../../lib/editor/geometry';
  import {
    canFill,
    isFreehand,
    isSegment,
    makeAnnotation,
    standardize,
    type Annotation,
    type Point,
    type Rect,
  } from '../../lib/editor/model';
  import {
    drawCanvas,
    drawCropOverlay,
    drawSelection,
    handleRects,
    measureText,
    TEXT_FONT,
    TEXT_LINE_HEIGHT,
  } from '../../lib/editor/renderer';
  import type { EditSession } from '../../lib/editor/session.svelte';
  import { TOOL_INFO, toolForKey, type Tool } from '../../lib/editor/tools';
  import { accentColor } from '../../lib/theme';

  // The drawing surface (CanvasView.swift). A fixed canvas paints the visible part; a scroller on top
  // provides scrollbars and receives the mouse. Coordinates are canvas points (image plus padding), y-down.
  let { session }: { session: EditSession } = $props();

  const doc = $derived(session.document);

  type Gesture =
    | { kind: 'none' }
    | { kind: 'pendingShape'; anchor: Point; tool: Tool }
    | { kind: 'drawingShape'; id: string; anchor: Point }
    | { kind: 'moving'; id: string; last: Point; registered: boolean }
    | { kind: 'resizing'; id: string; handle: Handle; original: Annotation }
    | { kind: 'cropNew'; anchor: Point }
    | { kind: 'cropMove'; start: Point; original: Rect }
    | { kind: 'cropResize'; handle: Handle; original: Rect };

  let gesture: Gesture = { kind: 'none' };

  let viewport = $state<HTMLDivElement>();
  let scroller = $state<HTMLDivElement>();
  let paint = $state<HTMLCanvasElement>();
  let field = $state<HTMLTextAreaElement>();
  let vw = $state(0);
  let vh = $state(0);
  let scrollX = $state(0);
  let scrollY = $state(0);

  let textId = $state<string | null>(null);
  let textValue = $state('');
  let committingText = false;
  let menu = $state<{ x: number; y: number; items: MenuItem[] } | null>(null);

  const layout = $derived(session.displayLayout);
  const size = $derived(canvasSize(layout));
  const zoom = $derived(session.zoom);
  const contentW = $derived(size.w * zoom);
  const contentH = $derived(size.h * zoom);
  // Keeps the canvas centred while it is smaller than the viewport.
  const originX = $derived(Math.max(0, (vw - contentW) / 2));
  const originY = $derived(Math.max(0, (vh - contentH) / 2));

  const cursor = $derived(
    session.isCropping ? 'crosshair' : session.tool === 'select' ? 'default' : session.tool === 'text' ? 'text' : 'crosshair',
  );

  /** A distance of `n` screen pixels, in canvas units. */
  const screen = (n: number) => n / Math.max(zoom, 0.01);

  // ---------------------------------------------------------------- painting

  let frame = 0;
  $effect(() => {
    // Everything the picture depends on; reading them subscribes the effect.
    void [doc.annotations, doc.selectionId, layout, session.pendingCrop, session.tool, zoom, scrollX, scrollY, vw, vh, textId];
    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(draw);
  });

  function draw() {
    if (!paint) return;
    const dpr = window.devicePixelRatio || 1;
    const w = Math.round(vw * dpr),
      h = Math.round(vh * dpr);
    if (paint.width !== w || paint.height !== h) {
      paint.width = w;
      paint.height = h;
    }
    const ctx = paint.getContext('2d');
    if (!ctx) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, w, h);
    ctx.setTransform(dpr * zoom, 0, 0, dpr * zoom, dpr * (originX - scrollX), dpr * (originY - scrollY));
    drawCanvas(ctx, session.source, layout, doc.annotations, textId);
    if (session.isCropping) {
      if (session.pendingCrop) drawCropOverlay(ctx, session.pendingCrop, layout, screen(1), doc.scale);
    } else {
      const sel = doc.selectedItem;
      if (sel && sel.id !== textId) drawSelection(ctx, sel, layout, screen(1), accentColor());
    }
  }

  // ---------------------------------------------------------------- zoom and scrolling

  async function setZoom(z: number, anchor?: { x: number; y: number }) {
    if (!scroller) {
      session.zoom = z;
      return;
    }
    const ax = anchor?.x ?? vw / 2,
      ay = anchor?.y ?? vh / 2;
    // Canvas point under the anchor stays under it.
    const cx = (scroller.scrollLeft + ax - originX) / zoom,
      cy = (scroller.scrollTop + ay - originY) / zoom;
    session.zoom = clampZoom(z);
    await tick();
    scroller.scrollLeft = cx * session.zoom + originX - ax;
    scroller.scrollTop = cy * session.zoom + originY - ay;
    onscroll();
  }

  function onscroll() {
    if (!scroller) return;
    scrollX = scroller.scrollLeft;
    scrollY = scroller.scrollTop;
  }

  function onwheel(e: WheelEvent) {
    if (!e.ctrlKey || !scroller) return;
    e.preventDefault();
    const r = scroller.getBoundingClientRect();
    void setZoom(zoom * Math.exp(-e.deltaY / 400), { x: e.clientX - r.left, y: e.clientY - r.top });
  }

  // Canvas size depends on crop and backdrop; refit when it changes (EditSession.layoutChanged).
  let fittedSize = '';
  $effect(() => {
    const key = `${size.w}x${size.h}`;
    if (vw === 0 || vh === 0 || key === fittedSize) return;
    fittedSize = key;
    queueMicrotask(() => session.zoomToFit());
  });

  onMount(() => {
    const ro = new ResizeObserver(() => {
      if (!viewport) return;
      vw = viewport.clientWidth;
      vh = viewport.clientHeight;
    });
    if (viewport) ro.observe(viewport);
    session.canvas = {
      endTextSession,
      viewportSize: () => ({ w: vw, h: vh }),
      setZoom: (z) => void setZoom(z),
      focus: () => scroller?.focus({ preventScroll: true }),
    };
    scroller?.focus({ preventScroll: true });
    const redraw = () => draw();
    const themeObserver = new MutationObserver(redraw);
    themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'style'] });
    return () => {
      ro.disconnect();
      themeObserver.disconnect();
      cancelAnimationFrame(frame);
      endTextSession();
      session.canvas = null;
      window.removeEventListener('mousemove', onmousemove);
      window.removeEventListener('mouseup', onmouseup);
    };
  });

  // ---------------------------------------------------------------- hit testing

  function pointsFor(e: MouseEvent): { canvas: Point; doc: Point } {
    const r = scroller!.getBoundingClientRect();
    const c = {
      x: (e.clientX - r.left + scroller!.scrollLeft - originX) / zoom,
      y: (e.clientY - r.top + scroller!.scrollTop - originY) / zoom,
    };
    return { canvas: c, doc: canvasToDoc(layout, c) };
  }

  function handleAt(p: Point, a: Annotation): Handle | null {
    const tol = screen(4);
    for (const [h, r] of handleRects(a, layout, screen(1))) {
      if (contains({ x: r.x - tol, y: r.y - tol, w: r.w + 2 * tol, h: r.h + 2 * tol }, p)) return h;
    }
    return null;
  }

  function cropHandleAt(c: Point): Handle | null {
    if (!session.pendingCrop) return null;
    const r = docRectToCanvas(layout, standardize(session.pendingCrop));
    const tol = screen(10);
    return rectHandles(r).find(([, q]) => Math.abs(q.x - c.x) < tol && Math.abs(q.y - c.y) < tol)?.[0] ?? null;
  }

  // ---------------------------------------------------------------- mouse

  function onmousedown(e: MouseEvent) {
    if (e.button !== 0 || !scroller) return;
    // Clicks on the scrollbars scroll; they are not canvas clicks.
    const r = scroller.getBoundingClientRect();
    if (e.clientX - r.left >= scroller.clientWidth || e.clientY - r.top >= scroller.clientHeight) return;
    e.preventDefault();
    scroller.focus({ preventScroll: true });
    if (textId) {
      endTextSession();
      return;
    }
    const { canvas: c, doc: p } = pointsFor(e);
    begin(e, c, p);
    if (gesture.kind !== 'none') {
      window.addEventListener('mousemove', onmousemove);
      window.addEventListener('mouseup', onmouseup);
    }
  }

  function begin(e: MouseEvent, c: Point, p: Point) {
    if (session.isCropping) {
      const draft = session.pendingCrop ? standardize(session.pendingCrop) : null;
      const h = cropHandleAt(c);
      const full = draft && draft.x === 0 && draft.y === 0 && draft.w === doc.pointSize.w && draft.h === doc.pointSize.h;
      if (h && draft) gesture = { kind: 'cropResize', handle: h, original: draft };
      // An untouched full-image draft can't be moved; dragging draws a new crop instead.
      else if (draft && contains(draft, p) && !full) gesture = { kind: 'cropMove', start: p, original: draft };
      else gesture = { kind: 'cropNew', anchor: clampPoint(p, doc.pointSize) };
      return;
    }

    // The selected annotation's handles win regardless of tool.
    const sel = doc.selectedItem;
    const h = sel ? handleAt(c, sel) : null;
    if (sel && h) {
      gesture = { kind: 'resizing', id: sel.id, handle: h, original: sel };
      doc.registerUndo();
      return;
    }

    const tool = session.tool;
    const hit = hitTest(doc.annotations, p, screen(6));

    if (tool === 'select' || (hit && hit.id === doc.selectionId)) {
      if (!hit) {
        doc.selectionId = null;
        return;
      }
      doc.selectionId = hit.id;
      if (e.detail === 2 && hit.type === 'text') {
        beginTextSession(hit);
        return;
      }
      gesture = { kind: 'moving', id: hit.id, last: p, registered: false };
      return;
    }

    switch (tool) {
      case 'text':
        if (hit && hit.type === 'text') {
          doc.selectionId = hit.id;
          beginTextSession(hit);
        } else beginNewTextSession(p);
        break;
      case 'step': {
        doc.registerUndo();
        const d = session.textSize;
        const a = makeAnnotation('step', {
          frame: { x: p.x - d / 2, y: p.y - d / 2, w: d, h: d },
          color: session.color,
          textSize: d,
          step: doc.nextStep,
        });
        doc.add(a);
        doc.selectionId = a.id;
        doc.didChange();
        break;
      }
      default:
        doc.selectionId = null;
        gesture = { kind: 'pendingShape', anchor: p, tool };
    }
  }

  function onmousemove(e: MouseEvent) {
    if (!scroller) return;
    const { doc: p } = pointsFor(e);
    drag(p, e.shiftKey);
  }

  function drag(p: Point, shift: boolean) {
    const g = gesture;
    switch (g.kind) {
      case 'pendingShape': {
        const type = TOOL_INFO[g.tool].type;
        if (Math.hypot(p.x - g.anchor.x, p.y - g.anchor.y) <= screen(3) || !type) return;
        doc.registerUndo();
        const a = makeAnnotation(type, {
          color: session.color,
          stroke: session.stroke,
          filled: session.filled && canFill(type),
          redaction: session.redaction,
          textSize: session.textSize,
          frame: { x: g.anchor.x, y: g.anchor.y, w: 0, h: 0 },
          points: isFreehand(type) ? [g.anchor] : isSegment(type) ? [g.anchor, g.anchor] : [],
        });
        doc.add(a);
        doc.selectionId = a.id;
        gesture = { kind: 'drawingShape', id: a.id, anchor: g.anchor };
        drag(p, shift);
        break;
      }
      case 'drawingShape':
        doc.update(g.id, (a) => {
          if (isFreehand(a.type)) {
            const last = a.points.at(-1);
            if (last && Math.hypot(last.x - p.x, last.y - p.y) >= screen(1)) a.points.push(p);
          } else if (isSegment(a.type)) {
            a.points = [g.anchor, shift ? snap45(g.anchor, p) : p];
          } else {
            a.frame = rectFrom(g.anchor, p, shift);
          }
        });
        break;
      case 'moving':
        if (!g.registered) doc.registerUndo();
        doc.offset(g.id, p.x - g.last.x, p.y - g.last.y);
        gesture = { ...g, last: p, registered: true };
        break;
      case 'resizing':
        doc.update(g.id, (a) => {
          if (g.handle === 'lineStart') a.points[0] = shift ? snap45(g.original.points[1], p) : p;
          else if (g.handle === 'lineEnd') a.points[1] = shift ? snap45(g.original.points[0], p) : p;
          else a.frame = resizeRect(standardize(g.original.frame), g.handle, p);
        });
        break;
      case 'cropNew':
        session.pendingCrop = rectFrom(g.anchor, clampPoint(p, doc.pointSize), shift);
        break;
      case 'cropMove': {
        const { w, h } = doc.pointSize;
        const r = g.original;
        session.pendingCrop = {
          ...r,
          x: Math.min(Math.max(r.x + p.x - g.start.x, 0), w - r.w),
          y: Math.min(Math.max(r.y + p.y - g.start.y, 0), h - r.h),
        };
        break;
      }
      case 'cropResize':
        session.pendingCrop = resizeRect(g.original, g.handle, clampPoint(p, doc.pointSize));
        break;
    }
  }

  function onmouseup() {
    window.removeEventListener('mousemove', onmousemove);
    window.removeEventListener('mouseup', onmouseup);
    const g = gesture;
    gesture = { kind: 'none' };
    if (g.kind === 'drawingShape') {
      const a = doc.find(g.id);
      if (a && isDegenerate(a)) doc.remove(g.id);
      doc.didChange();
    } else if ((g.kind === 'moving' && g.registered) || g.kind === 'resizing') {
      doc.didChange();
    }
  }

  // ---------------------------------------------------------------- keyboard

  /** Keys while the canvas has focus (CanvasView.keyDown). Ctrl shortcuts live in the editor pane. */
  function onkeydown(e: KeyboardEvent) {
    const mods = e.ctrlKey || e.altKey || e.metaKey;
    switch (e.key) {
      case 'Escape':
        if (session.isCropping) session.cancelCrop();
        else if (doc.selectionId) doc.selectionId = null;
        else if (session.tool !== 'select') session.selectTool('select');
        e.preventDefault();
        return;
      case 'Enter': {
        if (session.isCropping) {
          session.applyCrop();
          e.preventDefault();
          return;
        }
        const sel = doc.selectedItem;
        if (sel?.type === 'text') {
          beginTextSession(sel);
          e.preventDefault();
        }
        return;
      }
      case 'Delete':
      case 'Backspace':
        if (doc.selectionId) doc.delete(doc.selectionId);
        e.preventDefault();
        return;
      case 'ArrowLeft':
      case 'ArrowRight':
      case 'ArrowUp':
      case 'ArrowDown': {
        e.preventDefault();
        const id = doc.selectionId;
        if (!id || mods) return;
        const step = e.shiftKey ? 10 : 1;
        const dx = e.key === 'ArrowLeft' ? -step : e.key === 'ArrowRight' ? step : 0;
        const dy = e.key === 'ArrowUp' ? -step : e.key === 'ArrowDown' ? step : 0;
        doc.registerUndo();
        doc.offset(id, dx, dy);
        doc.didChange();
        return;
      }
    }
    if (!mods && e.key.length === 1) {
      const tool = toolForKey(e.key);
      if (tool) {
        e.preventDefault();
        session.selectTool(tool);
      }
    }
  }

  // ---------------------------------------------------------------- context menu

  function oncontextmenu(e: MouseEvent) {
    e.preventDefault();
    if (session.isCropping || textId) return;
    const hit = hitTest(doc.annotations, pointsFor(e).doc, screen(6));
    if (!hit) return;
    doc.selectionId = hit.id;
    const id = hit.id;
    menu = {
      x: e.clientX,
      y: e.clientY,
      items: [
        { label: 'Bring to front', onselect: () => doc.bringToFront(id) },
        { label: 'Send to back', onselect: () => doc.sendToBack(id) },
        { label: 'Duplicate', shortcut: 'Ctrl+D', onselect: () => doc.duplicate(id) },
        { separator: true },
        { label: 'Delete', shortcut: 'Del', onselect: () => doc.delete(id) },
      ],
    };
  }

  // ---------------------------------------------------------------- text editing

  function beginNewTextSession(p: Point) {
    const m = measureText('', session.textSize);
    const a = makeAnnotation('text', {
      color: session.color,
      textSize: session.textSize,
      frame: { x: p.x, y: p.y - m.h / 2, w: m.w, h: m.h },
    });
    doc.registerUndo();
    doc.add(a);
    doc.selectionId = a.id;
    startField(a);
  }

  function beginTextSession(a: Annotation) {
    doc.registerUndo();
    startField(a);
  }

  function startField(a: Annotation) {
    textId = a.id;
    textValue = a.text;
    void tick().then(() => {
      field?.focus({ preventScroll: true });
      field?.setSelectionRange(textValue.length, textValue.length);
    });
  }

  function oninput() {
    if (!textId) return;
    const m = measureText(textValue, doc.find(textId)?.textSize ?? 28);
    doc.update(textId, (a) => {
      a.text = textValue;
      a.frame = { ...a.frame, w: m.w, h: m.h };
    });
  }

  function onfieldkeydown(e: KeyboardEvent) {
    e.stopPropagation();
    // Enter keeps the text, Shift+Enter starts a new line, Esc also keeps it (like the macOS field).
    if ((e.key === 'Enter' && !e.shiftKey) || e.key === 'Escape') {
      e.preventDefault();
      endTextSession();
    }
  }

  function endTextSession() {
    const id = textId;
    if (!id || committingText) return;
    committingText = true;
    const text = textValue;
    textId = null;
    if (text.trim() === '') doc.remove(id);
    else {
      const a = doc.find(id);
      const m = measureText(text, a?.textSize ?? 28);
      doc.update(id, (x) => {
        x.text = text;
        x.frame = { ...x.frame, w: m.w, h: m.h };
      });
    }
    doc.didChange();
    committingText = false;
    scroller?.focus({ preventScroll: true });
  }

  const textAnnotation = $derived(textId ? doc.find(textId) : null);
  const fieldBox = $derived.by(() => {
    const a = textAnnotation;
    if (!a) return null;
    const o = docToCanvas(layout, { x: a.frame.x, y: a.frame.y });
    const m = measureText(textValue, a.textSize);
    return {
      left: originX + o.x * zoom,
      top: originY + o.y * zoom,
      width: (m.w + a.textSize) * zoom,
      height: (m.h + 4) * zoom,
      font: a.textSize * zoom,
      color: a.color,
    };
  });
</script>

<div class="viewport" bind:this={viewport}>
  <canvas class="paint" bind:this={paint} style:width="{vw}px" style:height="{vh}px"></canvas>
  <!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
  <div
    class="scroller"
    bind:this={scroller}
    tabindex="0"
    role="application"
    aria-label="Canvas"
    style:cursor
    {onscroll}
    {onwheel}
    {onmousedown}
    {onkeydown}
    {oncontextmenu}
  >
    <div class="spacer" style:width="{Math.max(contentW, vw)}px" style:height="{Math.max(contentH, vh)}px">
      {#if fieldBox}
        <textarea
          bind:this={field}
          bind:value={textValue}
          class="text-field"
          spellcheck="false"
          aria-label="Text"
          wrap="off"
          style:left="{fieldBox.left}px"
          style:top="{fieldBox.top}px"
          style:width="{fieldBox.width}px"
          style:height="{fieldBox.height}px"
          style:font-size="{fieldBox.font}px"
          style:padding-left="{2 * zoom}px"
          style:line-height={TEXT_LINE_HEIGHT}
          style:font-family={TEXT_FONT}
          style:color={fieldBox.color}
          style:caret-color={fieldBox.color}
          {oninput}
          onkeydown={onfieldkeydown}
          onblur={endTextSession}
          onmousedown={(e) => e.stopPropagation()}
        ></textarea>
      {/if}
    </div>
  </div>
</div>

{#if menu}
  <Menu x={menu.x} y={menu.y} items={menu.items} label="Annotation" onclose={() => (menu = null)} />
{/if}

<style>
  .viewport {
    position: relative;
    flex: 1;
    min-width: 0;
    min-height: 0;
    overflow: hidden;
    background: var(--canvas);
  }
  .paint {
    position: absolute;
    left: 0;
    top: 0;
    pointer-events: none;
  }
  .scroller {
    position: absolute;
    inset: 0;
    overflow: auto;
    outline: none;
  }
  .spacer {
    position: relative;
  }
  .text-field {
    position: absolute;
    margin: 0;
    padding: 0;
    border: 0;
    outline: none;
    background: transparent;
    font-weight: 600;
    resize: none;
    overflow: hidden;
    white-space: pre;
    user-select: text;
  }
</style>
