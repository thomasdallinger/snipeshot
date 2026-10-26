<script lang="ts">
  import { onMount, type Snippet } from 'svelte';
  import type { EditSession } from '../../lib/editor/session.svelte';
  import Canvas from './Canvas.svelte';
  import Header from './Header.svelte';
  import Inspector from './Inspector.svelte';
  import StatusBar from './StatusBar.svelte';

  // Header, canvas, inspector and status bar for one capture (EditorPane in EditorChrome.swift).
  interface Props {
    session: EditSession;
    showInspector: boolean;
    ontoggleinspector: () => void;
    leading?: Snippet;
  }

  let { session, showInspector, ontoggleinspector, leading }: Props = $props();

  let root = $state<HTMLDivElement>();

  /** Ctrl shortcuts work anywhere in the editor except while typing (CanvasView.performKeyEquivalent). */
  function onkeydown(e: KeyboardEvent) {
    if (!e.ctrlKey || e.altKey || e.metaKey) return;
    const target = e.target as HTMLElement;
    if (target.closest('input, textarea, select, [contenteditable]')) return;
    if (target !== document.body && !root?.contains(target)) return;
    const key = e.key.toLowerCase();
    const doc = session.document;
    let handled = true;
    if (e.shiftKey) {
      if (key === 'z') session.redo();
      else if (key === 'e') void session.export();
      else if (key === '+') session.zoomIn();
      else handled = false;
    } else {
      switch (key) {
        case 'z':
          session.undo();
          break;
        case 'y':
          session.redo();
          break;
        case 'c':
          void session.copyToClipboard();
          break;
        case 's':
          void session.save();
          break;
        case 'd':
          if (doc.selectionId) doc.duplicate(doc.selectionId);
          break;
        case '=':
        case '+':
          session.zoomIn();
          break;
        case '-':
          session.zoomOut();
          break;
        case '0':
          session.zoomToFit();
          break;
        case '1':
          session.zoomActualSize();
          break;
        default:
          handled = false;
      }
    }
    if (handled) e.preventDefault();
  }

  onMount(() => {
    window.addEventListener('keydown', onkeydown);
    return () => window.removeEventListener('keydown', onkeydown);
  });
</script>

<div class="editor" bind:this={root}>
  <Header {session} {showInspector} {ontoggleinspector} {leading} />
  <div class="body">
    <Canvas {session} />
    {#if showInspector}
      <Inspector {session} />
    {/if}
  </div>
  <StatusBar {session} />
</div>

<style>
  .editor {
    container: editor / inline-size;
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
    height: 100%;
  }
  .body {
    display: flex;
    flex: 1;
    min-height: 0;
  }
</style>
