<script lang="ts">
  import { Pencil } from '@lucide/svelte';
  import { fileSrc } from '../../lib/api';
  import { fileDrag } from '../../lib/fileDrag';
  import { baseName, pixelSize, timeOfDay } from '../../lib/format';
  import type { CaptureFile } from '../../lib/types';

  // One capture in the sidebar: thumbnail (also a file drag source), time, pixel size (CaptureRow in LibraryWindow.swift).
  interface Props {
    capture: CaptureFile;
    isOpen: boolean;
    onopen: () => void;
    oncontextmenu: (e: MouseEvent) => void;
  }

  let { capture, isOpen, onopen, oncontextmenu }: Props = $props();
</script>

<div
  class="row"
  class:open={isOpen}
  role="option"
  aria-selected={isOpen}
  tabindex="-1"
  title={baseName(capture.path)}
  data-path={capture.path}
  onclick={onopen}
  onkeydown={(e) => e.key === 'Enter' && onopen()}
  {oncontextmenu}
>
  <div class="thumb" use:fileDrag={{ path: capture.path }} title="Drag to share">
    <img src={fileSrc(capture.previewPath, capture.modifiedAt)} alt="" loading="lazy" decoding="async" draggable="false" />
  </div>
  <div class="text">
    <span class="time">{timeOfDay(capture.createdAt)}</span>
    <span class="size tabular">{pixelSize(capture.width, capture.height)}</span>
  </div>
  {#if capture.hasEdits}
    <span class="edited" title="Edited"><Pencil size={11} strokeWidth={2.25} /></span>
  {/if}
</div>

<style>
  .row {
    position: relative;
    display: flex;
    align-items: center;
    gap: 10px;
    margin: 1px 8px;
    padding: 5px 8px;
    border-radius: var(--r-thumb);
    outline: none;
  }
  .row:hover {
    background: var(--subtle-hover);
  }
  .row.open {
    background: var(--selection);
  }
  /* Windows 11 list selection: a short accent bar on the leading edge. */
  .row.open::before {
    content: '';
    position: absolute;
    left: 0;
    top: 50%;
    width: 3px;
    height: 18px;
    border-radius: 2px;
    background: var(--accent);
    transform: translateY(-50%);
  }
  .thumb {
    flex: none;
    width: 64px;
    height: 44px;
    border-radius: 5px;
    overflow: hidden;
    background: var(--subtle-active);
    box-shadow: inset 0 0 0 1px rgb(127 127 127 / 0.2);
  }
  .thumb img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
    pointer-events: none;
  }
  .text {
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
    flex: 1;
  }
  .time {
    font-size: 13px;
    color: var(--text-1);
  }
  .size {
    font-size: 11px;
    color: var(--text-2);
  }
  .edited {
    display: grid;
    color: var(--text-2);
  }
</style>
