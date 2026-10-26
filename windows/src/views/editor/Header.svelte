<script lang="ts">
  import {
    ArrowUpRight,
    Circle,
    Crop,
    Ellipsis,
    EyeOff,
    Highlighter,
    MousePointer2,
    PanelRight,
    Pencil,
    Redo2,
    Slash,
    Square,
    Type,
    Undo2,
  } from '@lucide/svelte';
  import type { Component, Snippet } from 'svelte';
  import Button from '../../lib/components/Button.svelte';
  import IconButton from '../../lib/components/IconButton.svelte';
  import Menu, { type MenuItem } from '../../lib/components/Menu.svelte';
  import StepIcon from '../../lib/components/StepIcon.svelte';
  import type { EditSession } from '../../lib/editor/session.svelte';
  import { TOOL_GROUPS, TOOL_INFO, type Tool } from '../../lib/editor/tools';

  // Tools on the left, undo/redo, More and Copy on the right (EditorHeader in EditorChrome.swift).
  interface Props {
    session: EditSession;
    showInspector: boolean;
    ontoggleinspector: () => void;
    /** Shown before the tools (the library's "Show sidebar" button). */
    leading?: Snippet;
  }

  let { session, showInspector, ontoggleinspector, leading }: Props = $props();

  const ICONS: Record<Tool, Component<{ size?: number; strokeWidth?: number }>> = {
    select: MousePointer2,
    rectangle: Square,
    ellipse: Circle,
    arrow: ArrowUpRight,
    line: Slash,
    pen: Pencil,
    highlighter: Highlighter,
    text: Type,
    step: StepIcon,
    redaction: EyeOff,
    crop: Crop,
  };

  let more = $state<{ x: number; y: number } | null>(null);

  const moreItems = $derived<MenuItem[]>([
    { label: 'Export…', shortcut: 'Ctrl+Shift+E', onselect: () => void session.export() },
    { label: 'Pin to screen', onselect: () => void session.pin() },
    { label: 'Show in Explorer', onselect: () => session.revealInExplorer() },
    ...(session.document.crop
      ? ([{ separator: true }, { label: 'Remove crop', onselect: () => session.removeCrop() }] as MenuItem[])
      : []),
    { separator: true },
    { label: 'Move to Recycle Bin', onselect: () => session.delete() },
  ]);

  function openMore(e: MouseEvent) {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    more = more ? null : { x: r.right - 220, y: r.bottom + 4 };
  }
</script>

<header class="header">
  {#if leading}{@render leading()}<span class="divider"></span>{/if}
  <div class="tools" role="toolbar" aria-label="Tools">
    {#each TOOL_GROUPS as group, i (i)}
      {#if i > 0}<span class="divider"></span>{/if}
      {#each group as tool (tool)}
        {@const Icon = ICONS[tool]}
        <IconButton
          label={TOOL_INFO[tool].title}
          title="{TOOL_INFO[tool].title} ({TOOL_INFO[tool].key.toUpperCase()})"
          active={session.tool === tool}
          onclick={() => session.selectTool(tool)}
        >
          <Icon size={16} strokeWidth={1.75} />
        </IconButton>
      {/each}
    {/each}
  </div>
  <div class="spacer"></div>
  <IconButton label="Undo" title="Undo (Ctrl+Z)" disabled={!session.document.canUndo} onclick={() => session.undo()}>
    <Undo2 size={16} strokeWidth={1.75} />
  </IconButton>
  <IconButton label="Redo" title="Redo (Ctrl+Y)" disabled={!session.document.canRedo} onclick={() => session.redo()}>
    <Redo2 size={16} strokeWidth={1.75} />
  </IconButton>
  <span class="divider"></span>
  <IconButton label="More" active={!!more} onclick={openMore}>
    <Ellipsis size={16} strokeWidth={1.75} />
  </IconButton>
  <Button variant="primary" title="Copy the edited image (Ctrl+C)" onclick={() => void session.copyToClipboard()}>Copy</Button>
  <IconButton
    label={showInspector ? 'Hide inspector' : 'Show inspector'}
    active={showInspector}
    onclick={ontoggleinspector}
  >
    <PanelRight size={16} strokeWidth={1.75} />
  </IconButton>
</header>

{#if more}
  <Menu x={more.x} y={more.y} items={moreItems} label="More" onclose={() => (more = null)} />
{/if}

<style>
  .header {
    display: flex;
    align-items: center;
    gap: 2px;
    height: 48px;
    padding: 0 8px;
    background: var(--window);
    border-bottom: 1px solid var(--line);
    flex: none;
    min-width: 0;
  }
  .tools {
    display: flex;
    align-items: center;
    gap: 2px;
  }
  .spacer {
    flex: 1;
    min-width: 12px;
  }
  .divider {
    width: 1px;
    height: 18px;
    margin: 0 6px;
    background: var(--line);
    flex: none;
  }
  .header :global(.button) {
    margin: 0 4px 0 6px;
  }

  /* The library's minimum width leaves ~576 px for the editor; tighten the chrome to fit. */
  @container editor (max-width: 700px) {
    .header,
    .tools {
      gap: 0;
    }
    .header :global(.icon-button) {
      width: 28px;
    }
    .divider {
      margin: 0 3px;
    }
    .header :global(.button) {
      min-width: 0;
      margin: 0 2px 0 4px;
    }
  }
</style>
