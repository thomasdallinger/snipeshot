<script lang="ts">
  import { Check, Copy, X } from '@lucide/svelte';
  import { onMount } from 'svelte';
  import IconButton from '../lib/components/IconButton.svelte';
  import { api, fileSrc, isTauri, resizeWindowCentered, startWindowDrag, windowLogicalSize } from '../lib/api';
  import { reduceMotion } from '../lib/theme';

  // Floats a capture above all windows. Drag to move, scroll to resize, Esc or double-click to close.
  interface Props {
    path: string;
    /** Pixels per point of the image. */
    scale: number;
  }

  let { path, scale }: Props = $props();

  const src = $derived(fileSrc(path));
  const animate = !reduceMotion();

  let hovering = $state(false);
  let copied = $state(false);
  /** Size multiplier relative to the size the window opened with. */
  let zoom = $state(1);
  let base = { width: 0, height: 0 };
  /** Browser preview only: the image's size in points. */
  let natural = $state<{ width: number; height: number } | null>(null);
  let resizing: Promise<void> | null = null;
  let pendingResize = false;
  let copiedTimer: ReturnType<typeof setTimeout> | undefined;

  onMount(() => {
    if (isTauri) void windowLogicalSize().then((s) => (base = s));
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') void api.closeWindow();
    };
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('keydown', onKey);
      clearTimeout(copiedTimer);
    };
  });

  function onload(e: Event) {
    const img = e.currentTarget as HTMLImageElement;
    // Same sizing as Rust: point size, at most 60% of the screen.
    const w = img.naturalWidth / scale,
      h = img.naturalHeight / scale;
    const fit = Math.min(1, (innerWidth * 0.6) / w, (innerHeight * 0.6) / h);
    natural = { width: w * fit, height: h * fit };
  }

  function onmousedown(e: MouseEvent) {
    if (e.button !== 0 || (e.target as HTMLElement).closest('button')) return;
    // Starting a native move swallows the second click, so a double-click is caught here.
    if (e.detail >= 2) {
      void api.closeWindow();
      return;
    }
    void startWindowDrag();
  }

  function onwheel(e: WheelEvent) {
    e.preventDefault();
    const factor = 1 - Math.max(-0.25, Math.min(0.25, e.deltaY / 1000));
    zoom = Math.min(Math.max(zoom * factor, 0.15), 4);
    if (isTauri) resizeWindow();
  }

  /** Coalesces wheel events: one window resize in flight, the latest zoom wins. */
  function resizeWindow() {
    if (!base.width) return;
    if (resizing) {
      pendingResize = true;
      return;
    }
    resizing = resizeWindowCentered(base.width * zoom, base.height * zoom)
      .catch((err) => console.error('resize failed', err))
      .finally(() => {
        resizing = null;
        if (pendingResize) {
          pendingResize = false;
          resizeWindow();
        }
      });
  }

  async function copy() {
    try {
      const res = await fetch(src);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      await api.copyPng(new Uint8Array(await res.arrayBuffer()));
    } catch (err) {
      console.warn('copy_png failed, copying the file instead', err);
      await api.copyCapture(path);
    }
    copied = true;
    clearTimeout(copiedTimer);
    copiedTimer = setTimeout(() => (copied = false), 1200);
  }
</script>

<div class="page" class:browser={!isTauri} {onwheel}>
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="pin"
    class:animate
    style:width={!isTauri && natural ? `${natural.width * zoom}px` : null}
    style:height={!isTauri && natural ? `${natural.height * zoom}px` : null}
    title="Drag to move. Scroll to resize. Double-click or press Esc to close."
    onpointerenter={() => (hovering = true)}
    onpointerleave={() => (hovering = false)}
    {onmousedown}
  >
    <img {src} alt="Pinned capture" draggable="false" {onload} />
    {#if copied}
      <div class="copied"><Check size={14} strokeWidth={2.5} /><span>Copied</span></div>
    {/if}
    {#if hovering}
      <div class="actions">
        <IconButton label="Close" title="Close (Esc)" size="small" onImage onclick={() => api.closeWindow()}>
          <X size={14} />
        </IconButton>
        <IconButton label="Copy" size="small" onImage onclick={copy}><Copy size={14} /></IconButton>
      </div>
    {/if}
  </div>
</div>

<style>
  .page {
    height: 100%;
  }
  /* Browser preview: a neutral page with the pin at its point size in the middle. */
  .browser {
    display: grid;
    place-items: center;
    overflow: hidden;
    background: var(--canvas);
  }
  .pin {
    position: relative;
    width: 100%;
    height: 100%;
    overflow: hidden;
    border-radius: 8px;
  }
  .browser .pin {
    max-width: none;
  }
  .pin::after {
    content: '';
    position: absolute;
    inset: 0;
    border-radius: inherit;
    border: 1px solid rgb(0 0 0 / 0.2);
    pointer-events: none;
  }
  .animate {
    animation: fade-in 150ms var(--ease);
  }
  @keyframes fade-in {
    from {
      opacity: 0;
    }
  }
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: contain;
    pointer-events: none;
  }
  .actions {
    position: absolute;
    top: 6px;
    left: 6px;
    display: flex;
    gap: 6px;
  }
  .copied {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    background: rgb(0 0 0 / 0.45);
    color: #fff;
    font-size: 12px;
    font-weight: 600;
    pointer-events: none;
  }
</style>
