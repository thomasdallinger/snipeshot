<script lang="ts" module>
  export type MenuItem =
    | { label: string; onselect: () => void; disabled?: boolean; shortcut?: string }
    | { separator: true };
</script>

<script lang="ts">
  import { onMount, tick } from 'svelte';

  // Context or drop-down menu at a viewport position. Closes on outside click, Esc or a choice.
  interface Props {
    x: number;
    y: number;
    items: MenuItem[];
    label: string;
    /** Open upwards from `y` (menus anchored to the status bar). */
    above?: boolean;
    onclose: () => void;
  }

  let { x, y, items, label, above = false, onclose }: Props = $props();

  let el = $state<HTMLDivElement>();
  let pos = $state({ left: 0, top: 0 });

  onMount(() => {
    void tick().then(() => {
      if (!el) return;
      // Keep the menu on screen.
      const r = el.getBoundingClientRect();
      const top = above ? y - r.height : y;
      pos = {
        left: Math.max(4, Math.min(x, innerWidth - r.width - 4)),
        top: Math.max(4, Math.min(top, innerHeight - r.height - 4)),
      };
      el.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus();
    });
    const outside = (e: PointerEvent) => {
      if (el && !el.contains(e.target as Node)) onclose();
    };
    const blur = () => onclose();
    window.addEventListener('pointerdown', outside, true);
    window.addEventListener('blur', blur);
    return () => {
      window.removeEventListener('pointerdown', outside, true);
      window.removeEventListener('blur', blur);
    };
  });

  function onkeydown(e: KeyboardEvent) {
    const buttons = [...(el?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') ?? [])];
    const i = buttons.indexOf(document.activeElement as HTMLButtonElement);
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      onclose();
    } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      e.stopPropagation();
      const next = (i + (e.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length;
      buttons[next]?.focus();
    } else if (e.key === 'Tab') {
      e.preventDefault();
    }
  }

  function choose(item: Extract<MenuItem, { label: string }>) {
    onclose();
    item.onselect();
  }
</script>

<!-- svelte-ignore a11y_interactive_supports_focus -->
<div
  bind:this={el}
  class="menu"
  role="menu"
  aria-label={label}
  style:left="{pos.left}px"
  style:top="{pos.top}px"
  {onkeydown}
>
  {#each items as item, i (i)}
    {#if 'separator' in item}
      <div class="separator" role="separator"></div>
    {:else}
      <button type="button" role="menuitem" disabled={item.disabled} onclick={() => choose(item)}>
        <span>{item.label}</span>
        {#if item.shortcut}<span class="shortcut">{item.shortcut}</span>{/if}
      </button>
    {/if}
  {/each}
</div>

<style>
  .menu {
    position: fixed;
    z-index: 100;
    min-width: 180px;
    padding: 4px;
    border-radius: var(--r-card);
    background: var(--layer);
    box-shadow: var(--shadow-menu);
  }
  button {
    display: flex;
    align-items: center;
    gap: 24px;
    width: 100%;
    height: 30px;
    padding: 0 10px;
    border: 0;
    border-radius: var(--r-control);
    background: transparent;
    text-align: left;
  }
  button:hover:not(:disabled),
  button:focus-visible {
    background: var(--subtle-hover);
    outline: none;
  }
  button:disabled {
    color: var(--text-3);
  }
  .shortcut {
    margin-left: auto;
    color: var(--text-3);
    font-size: 12px;
  }
  .separator {
    height: 1px;
    margin: 4px 0;
    background: var(--line);
  }
</style>
