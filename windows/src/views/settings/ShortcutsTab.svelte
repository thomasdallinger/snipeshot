<script lang="ts">
  import { onMount } from 'svelte';
  import Button from '../../lib/components/Button.svelte';
  import { formatAccelerator, usesPrintScreen } from '../../lib/accelerator';
  import { api } from '../../lib/api';
  import { prefs, updatePrefs } from '../../lib/settings.svelte';
  import type { CaptureKind, Settings, ShortcutStatus } from '../../lib/types';
  import NoticeRow from './NoticeRow.svelte';
  import Row from './Row.svelte';
  import Section from './Section.svelte';
  import ShortcutRecorder from './ShortcutRecorder.svelte';

  interface Props {
    settings: Settings;
    onrecording: (recording: boolean) => void;
  }

  let { settings, onrecording }: Props = $props();

  const kinds: { kind: CaptureKind; title: string }[] = [
    { kind: 'area', title: 'Area' },
    { kind: 'window', title: 'Window' },
    { kind: 'screen', title: 'Whole screen' },
  ];

  let status = $state<ShortcutStatus>({ blocked: [], printScreenOpensSnippingTool: false });

  const snippingConflict = $derived(
    status.printScreenOpensSnippingTool && kinds.some((k) => usesPrintScreen(settings.shortcuts[k.kind])),
  );
  const blockedKeys = $derived(
    status.blocked
      .map((k) => settings.shortcuts[k])
      .filter((a): a is string => !!a)
      .map(formatAccelerator)
      .sort()
      .join(', '),
  );

  async function refresh() {
    try {
      status = await api.shortcutStatus();
    } catch (e) {
      console.error('shortcut_status failed', e);
    }
  }

  // Both problems change outside the app (registry, other apps), so poll while the window is visible.
  onMount(() => {
    void refresh();
    const timer = setInterval(() => {
      if (!document.hidden) void refresh();
    }, 1500);
    const onVisible = () => {
      if (!document.hidden) void refresh();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      clearInterval(timer);
      document.removeEventListener('visibilitychange', onVisible);
    };
  });

  async function turnOffSnippingTool() {
    status = await api.setPrintScreenOpensSnippingTool(false);
  }

  async function retry() {
    // Saving the same shortcuts makes Rust register them again.
    if (prefs.value) await updatePrefs({ shortcuts: { ...prefs.value.shortcuts } });
    await refresh();
  }

  async function setShortcut(kind: CaptureKind, value: string | null) {
    await updatePrefs({ shortcuts: { ...settings.shortcuts, [kind]: value } });
    await refresh();
  }

  async function useDefaults() {
    prefs.value = await api.resetShortcuts();
    await refresh();
  }
</script>

{#if snippingConflict || blockedKeys}
  <div class="notices">
    {#if snippingConflict}
      <NoticeRow text="Print Screen opens the Snipping Tool." button="Turn off" onclick={turnOffSnippingTool} />
    {/if}
    {#if blockedKeys}
      <NoticeRow
        text="Another app already uses {blockedKeys}. Quit it or choose different keys."
        button="Try again"
        onclick={retry}
      />
    {/if}
  </div>
{/if}

<Section>
  {#each kinds as k (k.kind)}
    <Row label={k.title}>
      <ShortcutRecorder
        label={k.title}
        value={settings.shortcuts[k.kind]}
        onchange={(v) => setShortcut(k.kind, v)}
        {onrecording}
      />
    </Row>
  {/each}
  {#snippet footer()}
    <div class="footer">
      <span>Click a shortcut and type the new keys. Delete clears it, Esc keeps the old one.</span>
      <Button size="small" onclick={useDefaults}>Use defaults</Button>
    </div>
  {/snippet}
</Section>

<style>
  .notices {
    margin-bottom: 16px;
  }
  .footer {
    display: flex;
    align-items: flex-start;
    gap: 16px;
  }
  .footer span {
    flex: 1;
    padding-top: 4px;
  }
</style>
