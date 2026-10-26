<script lang="ts">
  import { onMount } from 'svelte';
  import { backendReady } from './lib/api';
  import { parseRoute, type Route } from './lib/route';
  import { startPrefs } from './lib/settings.svelte';
  import Library from './views/Library.svelte';
  import Pin from './views/Pin.svelte';
  import Settings from './views/Settings.svelte';
  import Shelf from './views/Shelf.svelte';

  // All windows load the same bundle; the hash picks the view (docs/ipc.md).
  let route = $state<Route>(parseRoute(location.hash));
  let ready = $state(false);
  let failed = $state<string | null>(null);

  const transparent = $derived(route.view === 'shelf' || route.view === 'pin');

  onMount(() => {
    const onHash = () => (route = parseRoute(location.hash));
    window.addEventListener('hashchange', onHash);
    // The webview's own context menu (Reload, Inspect) has no place in a desktop app.
    const noMenu = (e: MouseEvent) => {
      const t = e.target as HTMLElement;
      if (!t.closest('input, textarea, .selectable')) e.preventDefault();
    };
    window.addEventListener('contextmenu', noMenu);
    void (async () => {
      try {
        await backendReady();
        await startPrefs();
        ready = true;
      } catch (e) {
        failed = e instanceof Error ? e.message : String(e);
      }
    })();
    return () => {
      window.removeEventListener('hashchange', onHash);
      window.removeEventListener('contextmenu', noMenu);
    };
  });

  $effect(() => {
    document.documentElement.classList.toggle('transparent', transparent);
    document.title = route.view === 'settings' ? 'Snipeshot Settings' : 'Snipeshot';
  });
</script>

{#if failed}
  <div class="failed" role="alert">
    <p class="title">Snipeshot could not start.</p>
    <p class="detail selectable">{failed}</p>
  </div>
{:else if ready}
  {#if route.view === 'settings'}
    <Settings initialTab={route.tab} />
  {:else if route.view === 'shelf'}
    <Shelf />
  {:else if route.view === 'pin'}
    <Pin path={route.path} scale={route.scale} />
  {:else}
    <Library />
  {/if}
{/if}

<style>
  .failed {
    display: grid;
    place-content: center;
    height: 100%;
    padding: 32px;
    text-align: center;
  }
  .title {
    margin: 0;
    font-size: 15px;
    font-weight: 600;
  }
  .detail {
    margin: 6px 0 0;
    color: var(--text-2);
  }
</style>
