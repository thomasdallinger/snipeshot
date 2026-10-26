<script lang="ts">
  import { PanelLeft } from '@lucide/svelte';
  import { onMount } from 'svelte';
  import { formatAccelerator } from '../lib/accelerator';
  import { api, on, onFileDrop, type Unlisten } from '../lib/api';
  import IconButton from '../lib/components/IconButton.svelte';
  import Keycap from '../lib/components/Keycap.svelte';
  import Menu, { type MenuItem } from '../lib/components/Menu.svelte';
  import { refreshStale } from '../lib/editor/flatten';
  import { EditSession } from '../lib/editor/session.svelte';
  import { prefs } from '../lib/settings.svelte';
  import type { CaptureFile } from '../lib/types';
  import Editor from './editor/Editor.svelte';
  import Sidebar from './library/Sidebar.svelte';

  // Captures on the left, the editor on the right (LibraryWindow.swift + LibraryModel.swift).
  let captures = $state.raw<CaptureFile[]>([]);
  let loaded = $state(false);
  let openPath = $state<string | null>(null);
  let session = $state<EditSession | null>(null);
  let loadError = $state<string | null>(null);
  let showSidebar = $state(localStorage.getItem('library.sidebar') !== 'hidden');
  let showInspector = $state(localStorage.getItem('library.inspector') !== 'hidden');
  let dropTarget = $state(false);
  let rowMenu = $state<{ x: number; y: number; items: MenuItem[] } | null>(null);

  const areaShortcut = $derived(prefs.value?.shortcuts.area ?? null);
  let openToken = 0;

  async function refresh() {
    captures = await api.listCaptures();
    loaded = true;
    refreshStale(captures);
  }

  async function open(path: string | null) {
    if (path === openPath && (path === null || session)) return;
    const token = ++openToken;
    const previous = session;
    session = null;
    loadError = null;
    openPath = path;
    // Persist the previous capture before letting it go.
    if (previous) void previous.close();
    const capture = path ? captures.find((c) => c.path === path) : null;
    if (!capture) return;
    try {
      const next = await EditSession.open(capture);
      if (token !== openToken) return;
      next.onDelete = (p) => void deleteCapture(p);
      session = next;
    } catch (e) {
      if (token === openToken) loadError = e instanceof Error ? e.message : String(e);
    }
  }

  /** Moves the selection up or down the list (arrow keys in the sidebar). */
  function openAdjacent(delta: number) {
    if (captures.length === 0) return;
    const i = captures.findIndex((c) => c.path === openPath);
    const j = Math.min(Math.max((i < 0 ? -delta : i) + delta, 0), captures.length - 1);
    void open(captures[j].path);
  }

  /** Opens the neighbour of a capture that is about to be removed. */
  function openNeighbor(path: string) {
    const i = captures.findIndex((c) => c.path === path);
    if (openPath !== path || i < 0) return;
    const next = captures[i + 1] ?? captures[i - 1] ?? null;
    void open(next?.path ?? null);
  }

  async function deleteCapture(path: string) {
    openNeighbor(path);
    await api.deleteCapture(path);
  }

  /** Rust reads the flattened cache, so the open capture's pending edits go out first. */
  async function settled(path: string) {
    if (session && session.document.path === path) await session.document.flush();
  }

  function showRowMenu(e: MouseEvent, c: CaptureFile) {
    e.preventDefault();
    rowMenu = {
      x: e.clientX,
      y: e.clientY,
      items: [
        { label: 'Copy', onselect: () => void settled(c.path).then(() => api.copyCapture(c.path)) },
        { label: 'Export…', onselect: () => void settled(c.path).then(() => api.exportCapture(c.path)) },
        { label: 'Pin to screen', onselect: () => void settled(c.path).then(() => api.pinCapture(c.path)) },
        { label: 'Show in Explorer', onselect: () => void api.showInExplorer(c.path) },
        { separator: true },
        { label: 'Move to Recycle Bin', onselect: () => void deleteCapture(c.path) },
      ],
    };
  }

  function toggleSidebar() {
    showSidebar = !showSidebar;
    localStorage.setItem('library.sidebar', showSidebar ? 'shown' : 'hidden');
  }

  function toggleInspector() {
    showInspector = !showInspector;
    localStorage.setItem('library.inspector', showInspector ? 'shown' : 'hidden');
  }

  onMount(() => {
    const unlisten: Promise<Unlisten>[] = [
      on('library-changed', () => void refresh()),
      on('edits-changed', () => void refresh()),
      on('open-capture', ({ path }) => {
        void refresh().then(() => open(path));
      }),
      onFileDrop({
        hover: (over) => (dropTarget = over),
        drop: (paths) => {
          void api.importFiles(paths).then(async (added) => {
            await refresh();
            if (added[0]) await open(added[0]);
          });
        },
      }),
    ];
    void refresh().then(() => {
      if (!openPath && captures[0]) void open(captures[0].path);
    });
    // The window hides instead of closing; keep edits safe whenever it goes away.
    const flush = () => {
      if (document.hidden) void session?.document.flush();
    };
    const unload = () => void session?.close();
    document.addEventListener('visibilitychange', flush);
    window.addEventListener('beforeunload', unload);
    return () => {
      for (const u of unlisten) void u.then((f) => f());
      document.removeEventListener('visibilitychange', flush);
      window.removeEventListener('beforeunload', unload);
      void session?.close();
    };
  });
</script>

{#snippet showSidebarButton()}
  <IconButton label="Show sidebar" onclick={toggleSidebar}>
    <PanelLeft size={16} strokeWidth={1.75} />
  </IconButton>
{/snippet}

<div class="library">
  {#if showSidebar}
    <Sidebar
      {captures}
      {openPath}
      {dropTarget}
      onopen={(p) => void open(p)}
      onadjacent={openAdjacent}
      ondelete={(p) => void deleteCapture(p)}
      onrowmenu={showRowMenu}
      onhide={toggleSidebar}
    />
  {/if}

  {#if session}
    {#key session}
      <Editor
        {session}
        {showInspector}
        ontoggleinspector={toggleInspector}
        leading={showSidebar ? undefined : showSidebarButton}
      />
    {/key}
  {:else}
    <div class="no-capture">
      <div class="bar">
        {#if !showSidebar}{@render showSidebarButton()}{/if}
      </div>
      <div class="message" class:drop={dropTarget && !showSidebar}>
        {#if loadError}
          <p class="title">This capture could not be opened.</p>
          <p class="hint selectable">{loadError}</p>
        {:else if loaded && !openPath}
          <p class="title">{captures.length === 0 ? 'Nothing captured yet' : 'Choose a capture'}</p>
          {#if areaShortcut}
            <p class="hint">Press <Keycap text={formatAccelerator(areaShortcut)} /> to capture an area.</p>
          {/if}
        {/if}
      </div>
    </div>
  {/if}
</div>

{#if rowMenu}
  <Menu x={rowMenu.x} y={rowMenu.y} items={rowMenu.items} label="Capture" onclose={() => (rowMenu = null)} />
{/if}

<style>
  .library {
    display: flex;
    height: 100%;
    min-width: 820px;
    min-height: 520px;
  }
  .no-capture {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
  }
  .bar {
    display: flex;
    align-items: center;
    height: 48px;
    padding: 0 8px;
    background: var(--window);
    border-bottom: 1px solid var(--line);
    flex: none;
  }
  .message {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    background: var(--canvas);
  }
  .message.drop {
    box-shadow: inset 0 0 0 2px var(--accent);
  }
  .message p {
    margin: 0;
  }
  .title {
    font-size: 15px;
    font-weight: 600;
  }
  .hint {
    color: var(--text-2);
  }
</style>
