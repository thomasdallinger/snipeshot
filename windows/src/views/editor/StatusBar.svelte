<script lang="ts">
  import { Minus, Plus } from '@lucide/svelte';
  import IconButton from '../../lib/components/IconButton.svelte';
  import Menu from '../../lib/components/Menu.svelte';
  import { outputPixelSize } from '../../lib/editor/geometry';
  import type { EditSession } from '../../lib/editor/session.svelte';

  // Size, save state and zoom (EditorStatusBar in EditorChrome.swift).
  let { session }: { session: EditSession } = $props();

  const out = $derived(outputPixelSize(session.document.layout(), session.document.scale));
  const saveState = $derived(session.notice ?? (session.document.isSaved ? 'Saved' : 'Saving…'));
  let zoomMenu = $state<{ x: number; y: number } | null>(null);

  function openZoomMenu(e: MouseEvent) {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    zoomMenu = zoomMenu ? null : { x: r.left, y: r.top - 4 };
  }
</script>

<footer class="status">
  <span class="tabular">{out.w} × {out.h} px</span>
  <span class="state" role="status">{saveState}</span>
  <span class="spacer"></span>
  <div class="zoom-group">
    <IconButton label="Zoom out" title="Zoom out (Ctrl+−)" size="small" onclick={session.zoomOut}>
      <Minus size={13} />
    </IconButton>
    <button type="button" class="zoom tabular" title="Zoom" onclick={openZoomMenu}>
      {Math.round(session.zoom * 100)}%
    </button>
    <IconButton label="Zoom in" title="Zoom in (Ctrl++)" size="small" onclick={session.zoomIn}>
      <Plus size={13} />
    </IconButton>
  </div>
</footer>

{#if zoomMenu}
  <Menu
    x={zoomMenu.x}
    y={zoomMenu.y}
    above
    label="Zoom"
    onclose={() => (zoomMenu = null)}
    items={[
      { label: 'Fit in window', shortcut: 'Ctrl+0', onselect: session.zoomToFit },
      { separator: true },
      { label: '50%', onselect: () => session.setZoom(0.5) },
      { label: '100%', shortcut: 'Ctrl+1', onselect: () => session.setZoom(1) },
      { label: '200%', onselect: () => session.setZoom(2) },
    ]}
  />
{/if}

<style>
  .status {
    display: flex;
    align-items: center;
    gap: 14px;
    height: 28px;
    padding: 0 8px 0 12px;
    font-size: 12px;
    color: var(--text-2);
    background: var(--window);
    border-top: 1px solid var(--line);
    flex: none;
  }
  .state {
    color: var(--text-3);
  }
  .spacer {
    flex: 1;
  }
  .zoom-group {
    display: flex;
    align-items: center;
  }
  .zoom {
    min-width: 48px;
    height: 22px;
    padding: 0 6px;
    border: 0;
    border-radius: var(--r-control);
    background: transparent;
    color: var(--text-2);
    font-size: 12px;
  }
  .zoom:hover {
    background: var(--subtle-hover);
    color: var(--text-1);
  }
</style>
