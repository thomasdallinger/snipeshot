<script lang="ts">
  import Button from '../../lib/components/Button.svelte';
  import Select from '../../lib/components/Select.svelte';
  import Slider from '../../lib/components/Slider.svelte';
  import { api } from '../../lib/api';
  import { updatePrefs } from '../../lib/settings.svelte';
  import type { FileFormat, Settings } from '../../lib/types';
  import Row from './Row.svelte';
  import Section from './Section.svelte';

  let { settings }: { settings: Settings } = $props();

  const formats: { value: FileFormat; label: string }[] = [
    { value: 'png', label: 'PNG' },
    { value: 'jpeg', label: 'JPEG' },
  ];

  /** Long paths lose their middle, so the drive and the folder name both stay visible. */
  function middleEllipsis(path: string, max = 38): string {
    if (path.length <= max) return path;
    const keep = max - 1;
    const head = Math.ceil(keep / 2);
    return `${path.slice(0, head)}…${path.slice(path.length - (keep - head))}`;
  }

  async function chooseFolder() {
    const folder = await api.chooseSaveFolder();
    if (folder) await updatePrefs({ saveFolder: folder });
  }
</script>

<Section>
  <Row label="Folder">
    <span class="path" title={settings.saveFolder}>{middleEllipsis(settings.saveFolder)}</span>
    <Button size="small" onclick={chooseFolder}>Change…</Button>
  </Row>
  <Row label="Format">
    <Select label="Format" options={formats} value={settings.fileFormat} onchange={(v) => updatePrefs({ fileFormat: v })} />
  </Row>
  {#if settings.fileFormat === 'jpeg'}
    <Row label="Quality">
      <div class="quality">
        <Slider
          label="JPEG quality"
          min={0.5}
          max={1}
          step={0.01}
          value={settings.jpegQuality}
          oninput={(v) => updatePrefs({ jpegQuality: v })}
        />
        <span class="percent tabular">{Math.round(settings.jpegQuality * 100)}%</span>
      </div>
    </Row>
  {/if}
  {#snippet footer()}
    Originals are never changed. Edits are kept in a small hidden file next to each capture.
  {/snippet}
</Section>

<Section>
  <Row label="Capture folder">
    <Button size="small" onclick={() => api.openSaveFolder()}>Show folder in Explorer</Button>
  </Row>
</Section>

<style>
  .path {
    max-width: 240px;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    color: var(--text-2);
  }
  .quality {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 220px;
  }
  .percent {
    width: 36px;
    text-align: right;
    color: var(--text-2);
  }
</style>
