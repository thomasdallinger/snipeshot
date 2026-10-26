<script lang="ts">
  import { onMount } from 'svelte';
  import { api, on } from '../lib/api';
  import { prefs } from '../lib/settings.svelte';
  import type { SettingsTab } from '../lib/types';
  import GeneralTab from './settings/GeneralTab.svelte';
  import SavingTab from './settings/SavingTab.svelte';
  import ShortcutsTab from './settings/ShortcutsTab.svelte';

  let { initialTab }: { initialTab: SettingsTab | null } = $props();

  const tabs: { id: SettingsTab; title: string }[] = [
    { id: 'general', title: 'General' },
    { id: 'shortcuts', title: 'Shortcuts' },
    { id: 'saving', title: 'Saving' },
  ];

  // Shortcuts first, like the macOS app: it is where first-run problems show up.
  // svelte-ignore state_referenced_locally
  let tab = $state<SettingsTab>(initialTab ?? 'shortcuts');
  let recording = $state(false);

  onMount(() => {
    const unlisten = on('open-settings-tab', (p) => (tab = p.tab));
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !recording && !e.defaultPrevented) {
        e.preventDefault();
        void api.closeWindow();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => {
      void unlisten.then((u) => u());
      window.removeEventListener('keydown', onKey);
    };
  });

  function onTabKey(e: KeyboardEvent) {
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
    e.preventDefault();
    const i = tabs.findIndex((t) => t.id === tab);
    const next = tabs[(i + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length];
    tab = next.id;
    document.getElementById(`tab-${next.id}`)?.focus();
  }
</script>

<div class="settings">
  <div class="tabs" role="tablist" aria-label="Settings" tabindex="-1" onkeydown={onTabKey}>
    {#each tabs as t (t.id)}
      <button
        type="button"
        role="tab"
        id="tab-{t.id}"
        aria-selected={tab === t.id}
        aria-controls="panel"
        tabindex={tab === t.id ? 0 : -1}
        class:selected={tab === t.id}
        onclick={() => (tab = t.id)}
      >
        {t.title}
      </button>
    {/each}
  </div>

  <div class="body" id="panel" role="tabpanel" aria-labelledby="tab-{tab}">
    {#if prefs.value}
      {#if tab === 'general'}
        <GeneralTab settings={prefs.value} />
      {:else if tab === 'shortcuts'}
        <ShortcutsTab settings={prefs.value} onrecording={(r) => (recording = r)} />
      {:else}
        <SavingTab settings={prefs.value} />
      {/if}
    {/if}
  </div>
</div>

<style>
  .settings {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: var(--window);
    font-size: 14px;
  }
  .tabs {
    display: flex;
    gap: 4px;
    padding: 10px 16px 0;
    flex: none;
  }
  .tabs:focus {
    outline: none;
  }
  [role='tab'] {
    position: relative;
    height: 36px;
    padding: 0 12px;
    border: 0;
    border-radius: var(--r-control);
    background: transparent;
    color: var(--text-2);
  }
  [role='tab']:hover {
    background: var(--subtle-hover);
    color: var(--text-1);
  }
  .selected {
    color: var(--text-1);
    font-weight: 600;
  }
  /* Windows 11 SelectorBar: a short accent bar under the selected item. */
  .selected::after {
    content: '';
    position: absolute;
    left: 50%;
    bottom: 2px;
    width: 16px;
    height: 3px;
    border-radius: 1.5px;
    background: var(--accent);
    transform: translateX(-50%);
  }
  .body {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 12px 16px 20px;
  }
</style>
