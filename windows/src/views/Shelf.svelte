<script lang="ts">
  import { onDestroy, onMount } from 'svelte';
  import { cubicOut } from 'svelte/easing';
  import { fly } from 'svelte/transition';
  import { api, on, type Unlisten } from '../lib/api';
  import { reduceMotion } from '../lib/theme';
  import type { ShelfItem } from '../lib/types';
  import ShelfCard from './shelf/ShelfCard.svelte';

  // Recent captures stacked in the bottom-left corner. Rust sizes and places the window;
  // this view only draws the cards, newest at the bottom.
  let items = $state<ShelfItem[]>([]);
  let copied = $state<Record<string, boolean>>({});
  const timers = new Map<string, ReturnType<typeof setTimeout>>();

  async function load() {
    items = await api.shelfItems();
  }

  function markCopied(path: string) {
    copied[path] = true;
    clearTimeout(timers.get(path));
    timers.set(
      path,
      setTimeout(() => (copied[path] = false), 1200),
    );
  }

  async function copy(path: string) {
    await api.copyCapture(path);
    markCopied(path);
  }

  // 160 ms ease-out from the left edge, or nothing when Reduce motion is on.
  function slideIn(node: Element) {
    return fly(node, { x: -218, duration: reduceMotion() ? 0 : 160, easing: cubicOut, opacity: 0 });
  }

  let unlisten: Unlisten[] = [];

  onMount(() => {
    void load();
    void Promise.all([
      on('shelf-changed', (next) => (items = next)),
      // A saved edit makes a fresh flattened preview; pick up the new path and cache buster.
      on('edits-changed', () => void load()),
      on('shelf-copied', (p) => markCopied(p.path)),
    ]).then((u) => (unlisten = u));
  });

  onDestroy(() => {
    unlisten.forEach((u) => u());
    timers.forEach((t) => clearTimeout(t));
    void api.shelfSetHover(false);
  });
</script>

<div class="shelf">
  <!-- While the pointer is over the cards, Rust keeps the shelf on this monitor. -->
  <div
    class="stack"
    role="list"
    aria-label="Recent captures"
    onpointerenter={() => api.shelfSetHover(true)}
    onpointerleave={() => api.shelfSetHover(false)}
  >
    {#each items as item (item.path)}
      <div role="listitem" in:slideIn>
        <ShelfCard {item} copied={!!copied[item.path]} oncopy={() => copy(item.path)} />
      </div>
    {/each}
  </div>
</div>

<style>
  .shelf {
    display: flex;
    flex-direction: column;
    justify-content: flex-end;
    height: 100%;
    padding: 18px;
    overflow: hidden;
  }
  .stack {
    display: flex;
    flex-direction: column;
    gap: 10px;
    width: 200px;
  }
</style>
