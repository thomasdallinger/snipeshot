<script lang="ts">
  import { AppWindow, Folder, Monitor, PanelLeft, Settings, SquareDashed } from '@lucide/svelte';
  import { onMount, tick } from 'svelte';
  import { formatAccelerator } from '../../lib/accelerator';
  import { api } from '../../lib/api';
  import IconButton from '../../lib/components/IconButton.svelte';
  import { groupByDay } from '../../lib/format';
  import { prefs } from '../../lib/settings.svelte';
  import type { CaptureFile, CaptureKind } from '../../lib/types';
  import CaptureRow from './CaptureRow.svelte';

  // Capture buttons, captures grouped by day, folder and settings (CaptureSidebar in LibraryWindow.swift).
  interface Props {
    captures: CaptureFile[];
    openPath: string | null;
    dropTarget: boolean;
    onopen: (path: string) => void;
    onadjacent: (delta: number) => void;
    ondelete: (path: string) => void;
    onrowmenu: (e: MouseEvent, capture: CaptureFile) => void;
    onhide: () => void;
  }

  let { captures, openPath, dropTarget, onopen, onadjacent, ondelete, onrowmenu, onhide }: Props = $props();

  let now = $state(new Date());
  let list = $state<HTMLDivElement>();
  const groups = $derived(groupByDay(captures, (c) => c.createdAt, now));

  const KINDS: { kind: CaptureKind; title: string; icon: typeof SquareDashed }[] = [
    { kind: 'area', title: 'Capture area', icon: SquareDashed },
    { kind: 'window', title: 'Capture window', icon: AppWindow },
    { kind: 'screen', title: 'Capture screen', icon: Monitor },
  ];

  function captureTitle(kind: CaptureKind, title: string) {
    const acc = prefs.value?.shortcuts[kind];
    return acc ? `${title} (${formatAccelerator(acc)})` : title;
  }

  onMount(() => {
    // Day titles roll over at midnight.
    const timer = setInterval(() => (now = new Date()), 60_000);
    return () => clearInterval(timer);
  });

  // Keep the open row in view (after keyboard moves or an "open-capture" from the shelf).
  $effect(() => {
    const path = openPath;
    if (!path || !list) return;
    void tick().then(() => {
      const row = [...(list?.querySelectorAll<HTMLElement>('[data-path]') ?? [])].find((r) => r.dataset.path === path);
      row?.scrollIntoView({ block: 'nearest' });
    });
  });

  function onkeydown(e: KeyboardEvent) {
    if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      e.preventDefault();
      onadjacent(e.key === 'ArrowUp' ? -1 : 1);
    } else if (e.key === 'Delete' && openPath) {
      e.preventDefault();
      ondelete(openPath);
    }
  }
</script>

<nav class="sidebar" class:drop={dropTarget} aria-label="Captures">
  <div class="top">
    <span class="spacer"></span>
    {#each KINDS as k (k.kind)}
      <IconButton label={k.title} title={captureTitle(k.kind, k.title)} onclick={() => void api.capture(k.kind)}>
        <k.icon size={16} strokeWidth={1.75} />
      </IconButton>
    {/each}
    <IconButton label="Hide sidebar" onclick={onhide}>
      <PanelLeft size={16} strokeWidth={1.75} />
    </IconButton>
  </div>

  {#if captures.length === 0}
    <div class="empty">
      <p class="title">No captures yet</p>
      <p class="hint">Drop images here to add them.</p>
    </div>
  {:else}
    <div class="list" bind:this={list} role="listbox" tabindex="0" aria-label="Captures" {onkeydown}>
      {#each groups as group (group.title)}
        <div class="group" role="group" aria-label={group.title}>
          <h3>{group.title}</h3>
          {#each group.items as capture (capture.path)}
            <CaptureRow
              {capture}
              isOpen={capture.path === openPath}
              onopen={() => {
                list?.focus({ preventScroll: true });
                onopen(capture.path);
              }}
              oncontextmenu={(e) => onrowmenu(e, capture)}
            />
          {/each}
        </div>
      {/each}
    </div>
  {/if}

  <div class="bottom">
    <IconButton label="Show capture folder" onclick={() => void api.openSaveFolder()}>
      <Folder size={16} strokeWidth={1.75} />
    </IconButton>
    <span class="spacer"></span>
    <IconButton label="Settings" onclick={() => void api.openSettings()}>
      <Settings size={16} strokeWidth={1.75} />
    </IconButton>
  </div>
</nav>

<style>
  .sidebar {
    position: relative;
    display: flex;
    flex-direction: column;
    width: 244px;
    flex: none;
    background: var(--sidebar);
    border-right: 1px solid var(--line);
  }
  .sidebar.drop::after {
    content: '';
    position: absolute;
    inset: 0;
    border: 2px solid var(--accent);
    pointer-events: none;
  }
  .top,
  .bottom {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 0 8px;
    flex: none;
  }
  .top {
    height: 48px;
  }
  .bottom {
    height: 40px;
    border-top: 1px solid var(--line);
  }
  .spacer {
    flex: 1;
  }
  .list {
    flex: 1;
    overflow-y: auto;
    padding-bottom: 8px;
    outline: none;
  }
  h3 {
    position: sticky;
    top: 0;
    z-index: 1;
    margin: 0;
    padding: 12px 16px 6px;
    font-size: 12px;
    font-weight: 600;
    color: var(--text-2);
    background: var(--sidebar);
  }
  .group:first-child h3 {
    padding-top: 4px;
  }
  .empty {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 16px;
    text-align: center;
  }
  .empty p {
    margin: 0;
  }
  .empty .title {
    font-weight: 600;
  }
  .empty .hint {
    font-size: 12px;
    color: var(--text-2);
  }
</style>
