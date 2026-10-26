<script lang="ts">
  import { Check, Copy, FolderOpen, Pencil, Pin, Trash2, X } from '@lucide/svelte';
  import IconButton from '../../lib/components/IconButton.svelte';
  import { api, fileSrc } from '../../lib/api';
  import { fileDrag } from '../../lib/fileDrag';
  import type { ShelfItem } from '../../lib/types';

  interface Props {
    item: ShelfItem;
    copied: boolean;
    oncopy: () => void;
  }

  let { item, copied, oncopy }: Props = $props();

  const CARD_WIDTH = 200;
  const height = $derived(Math.min(Math.max((CARD_WIDTH * item.height) / Math.max(item.width, 1), 72), 150));

  let hovering = $state(false);
  let dragging = $state(false);

  function edit() {
    void api.shelfRemove(item.path);
    void api.openLibrary(item.path);
  }

  function pin() {
    void api.shelfRemove(item.path);
    void api.pinCapture(item.path);
  }
</script>

<div
  class="card"
  class:dragging
  style:height="{height}px"
  title="Drag to share, click to edit"
  role="button"
  tabindex="0"
  aria-label="Capture, {item.width} × {item.height}"
  onpointerenter={() => (hovering = true)}
  onpointerleave={() => (hovering = false)}
  onkeydown={(e) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      edit();
    }
  }}
  use:fileDrag={{
    path: item.path,
    onclick: edit,
    ondragstart: () => (dragging = true),
    ondragend: () => (dragging = false),
  }}
>
  <img src={fileSrc(item.previewPath, item.modifiedAt)} alt="" draggable="false" />

  {#if copied}
    <div class="copied">
      <Check size={14} strokeWidth={2.5} />
      <span>Copied</span>
    </div>
  {:else if hovering && !dragging}
    <div class="close">
      <IconButton label="Close" size="small" onImage onclick={() => api.shelfRemove(item.path)}>
        <X size={14} />
      </IconButton>
    </div>
    <div class="bar">
      <IconButton label="Copy" size="small" onDark onclick={oncopy}><Copy size={14} /></IconButton>
      <IconButton label="Edit" size="small" onDark onclick={edit}><Pencil size={14} /></IconButton>
      <IconButton label="Pin to screen" size="small" onDark onclick={pin}><Pin size={14} /></IconButton>
      <IconButton label="Show in Explorer" size="small" onDark onclick={() => api.showInExplorer(item.path)}>
        <FolderOpen size={14} />
      </IconButton>
      <span class="spacer"></span>
      <IconButton label="Move to Recycle Bin" size="small" onDark onclick={() => api.deleteCapture(item.path)}>
        <Trash2 size={14} />
      </IconButton>
    </div>
  {/if}
</div>

<style>
  .card {
    position: relative;
    flex: none;
    width: 200px;
    overflow: hidden;
    border-radius: 10px;
    background: var(--window);
    /* Fits inside the 18 px of transparent room Rust leaves around the cards. */
    box-shadow: 0 4px 12px rgb(0 0 0 / 0.22);
  }
  /* Hairline edge drawn above the image so light screenshots keep their outline. */
  .card::after {
    content: '';
    position: absolute;
    inset: 0;
    border-radius: inherit;
    border: 1px solid rgb(0 0 0 / 0.18);
    pointer-events: none;
  }
  .card:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
  }
  .dragging {
    opacity: 0.6;
  }
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
    pointer-events: none;
  }
  .close {
    position: absolute;
    top: 6px;
    left: 6px;
  }
  .bar {
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    display: flex;
    align-items: center;
    height: 30px;
    padding: 0 4px;
    background: rgb(0 0 0 / 0.62);
  }
  .spacer {
    flex: 1;
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
