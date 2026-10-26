<script lang="ts">
  import Select from '../../lib/components/Select.svelte';
  import Toggle from '../../lib/components/Toggle.svelte';
  import { prefs, updatePrefs } from '../../lib/settings.svelte';
  import type { Appearance, Settings } from '../../lib/types';
  import Row from './Row.svelte';
  import Section from './Section.svelte';

  let { settings }: { settings: Settings } = $props();

  const appearances: { value: Appearance; label: string }[] = [
    { value: 'system', label: 'Match system' },
    { value: 'light', label: 'Light' },
    { value: 'dark', label: 'Dark' },
  ];

  type Flag = 'showShelf' | 'copyAfterCapture' | 'editAfterCapture' | 'captureSound' | 'closeShelfItemAfterDrag';
  const afterCapture: { key: Flag; label: string }[] = [
    { key: 'showShelf', label: 'Show it in the corner of the screen' },
    { key: 'copyAfterCapture', label: 'Put it on the clipboard' },
    { key: 'editAfterCapture', label: 'Open it in the editor' },
    { key: 'captureSound', label: 'Play a sound' },
    { key: 'closeShelfItemAfterDrag', label: 'Remove the card once it has been dragged out' },
  ];
</script>

<Section>
  <Row label="Open at login">
    <Toggle
      label="Open at login"
      checked={settings.openAtLogin}
      onchange={(v) => updatePrefs({ openAtLogin: v })}
    />
  </Row>
  <Row label="Appearance">
    <Select
      label="Appearance"
      options={appearances}
      value={settings.appearance}
      onchange={(v) => updatePrefs({ appearance: v })}
    />
  </Row>
</Section>

<Section title="After a capture">
  {#each afterCapture as item (item.key)}
    <Row label={item.label}>
      <Toggle label={item.label} checked={settings[item.key]} onchange={(v) => updatePrefs({ [item.key]: v })} />
    </Row>
  {/each}
  {#snippet footer()}
    {#if prefs.version}<span class="version selectable">Snipeshot {prefs.version}</span>{/if}
  {/snippet}
</Section>

<style>
  .version {
    color: var(--text-3);
  }
</style>
