<script lang="ts">
  import Button from '../../lib/components/Button.svelte';
  import Segmented from '../../lib/components/Segmented.svelte';
  import Slider from '../../lib/components/Slider.svelte';
  import Toggle from '../../lib/components/Toggle.svelte';
  import {
    BACKDROP_PRESETS,
    canFill,
    nearestPreset,
    PALETTE,
    PRESET_COLORS,
    presetTitle,
    REDACTIONS,
    REDACTION_TITLES,
    sameFill,
    STROKE_PRESETS,
    TEXT_SIZE_PRESETS,
    TYPE_NAMES,
    usesStroke,
    usesTextSize,
    type Redaction,
  } from '../../lib/editor/model';
  import { standardize } from '../../lib/editor/model';
  import type { EditSession } from '../../lib/editor/session.svelte';

  // Style, Arrange, Crop and Backdrop sections, contextual to the tool or selection (Inspector in EditorChrome.swift).
  let { session }: { session: EditSession } = $props();

  const doc = $derived(session.document);
  const type = $derived(session.styleTarget);
  const selected = $derived(doc.selectedItem);
  const backdrop = $derived(doc.backdrop);
  const draft = $derived(session.pendingCrop ? standardize(session.pendingCrop) : null);
  const customBackdrop = $derived(backdrop.fill.kind === 'color' ? backdrop.fill.color : '#FFFFFF');
  const isPaletteColor = $derived(PALETTE.some((p) => p.color === session.currentColor));
</script>

<aside class="inspector" aria-label="Inspector">
  {#if session.isCropping}
    <section>
      <h2>Crop</h2>
      {#if draft}
        <p class="value tabular">{Math.round(draft.w * doc.scale)} × {Math.round(draft.h * doc.scale)} px</p>
      {/if}
      <p class="hint">Drag across the image or move the edges. Enter keeps the crop, Esc leaves it as it was.</p>
      <div class="buttons">
        <Button variant="primary" size="small" onclick={() => session.applyCrop()}>Done</Button>
        <Button size="small" onclick={() => session.resetCropDraft()}>Reset</Button>
        <Button size="small" onclick={() => session.cancelCrop()}>Cancel</Button>
      </div>
    </section>
  {:else if type}
    <section>
      <h2>{selected ? TYPE_NAMES[type] : `New ${TYPE_NAMES[type].toLowerCase()}`}</h2>
      {#if type !== 'redaction'}
        <div class="swatches" role="radiogroup" aria-label="Colour">
          {#each PALETTE as item (item.name)}
            <button
              type="button"
              role="radio"
              class="swatch"
              class:selected={item.color === session.currentColor}
              aria-checked={item.color === session.currentColor}
              aria-label={item.name}
              title={item.name}
              style:--swatch={item.color}
              onclick={() => session.setColor(item.color)}
            ></button>
          {/each}
          <label class="custom" class:selected={!isPaletteColor} title="Custom colour">
            <span class="visually-hidden">Custom colour</span>
            <input
              type="color"
              value={session.currentColor.slice(0, 7)}
              onchange={(e) => session.setColor(e.currentTarget.value.toUpperCase())}
            />
          </label>
        </div>
      {/if}
      {#if usesStroke(type)}
        <div class="row">
          <span>Stroke</span>
          <div class="control" style:width="140px">
            <Segmented
              label="Stroke"
              options={STROKE_PRESETS.map((p) => ({ value: p.value, label: p.title, title: `${p.value} pt` }))}
              value={nearestPreset(STROKE_PRESETS, session.currentStroke)}
              onchange={(v) => session.setStroke(v)}
            />
          </div>
        </div>
      {/if}
      {#if canFill(type)}
        <div class="row">
          <span>Fill</span>
          <Toggle label="Fill" checked={session.currentFilled} onchange={(v) => session.setFilled(v)} />
        </div>
      {/if}
      {#if usesTextSize(type)}
        <div class="row">
          <span>Size</span>
          <div class="control" style:width="108px">
            <Segmented
              label="Size"
              options={TEXT_SIZE_PRESETS.map((p) => ({ value: p.value, label: p.title, title: `${p.value} pt` }))}
              value={nearestPreset(TEXT_SIZE_PRESETS, session.currentTextSize)}
              onchange={(v) => session.setTextSize(v)}
            />
          </div>
        </div>
      {/if}
      {#if type === 'redaction'}
        <Segmented
          label="Redaction style"
          options={REDACTIONS.map((r) => ({ value: r, label: REDACTION_TITLES[r] }))}
          value={session.currentRedaction}
          onchange={(v: Redaction) => session.setRedaction(v)}
        />
      {/if}
    </section>
  {:else}
    <p class="hint">Pick a tool, or select something on the canvas to change its style.</p>
  {/if}

  {#if selected && !session.isCropping}
    {@const id = selected.id}
    <section>
      <h2>Arrange</h2>
      <div class="buttons">
        <Button size="small" title="Bring to front" onclick={() => doc.bringToFront(id)}>Front</Button>
        <Button size="small" title="Send to back" onclick={() => doc.sendToBack(id)}>Back</Button>
        <Button size="small" title="Duplicate (Ctrl+D)" onclick={() => doc.duplicate(id)}>Duplicate</Button>
      </div>
      <div class="buttons">
        <Button size="small" variant="danger" title="Delete (Del)" onclick={() => doc.delete(id)}>Delete</Button>
      </div>
    </section>
  {/if}

  {#if !session.isCropping}
    <section>
      <div class="section-head">
        <h2>Backdrop</h2>
        <Toggle label="Backdrop" checked={backdrop.enabled} onchange={(v) => session.updateBackdrop({ enabled: v })} />
      </div>
      {#if backdrop.enabled}
        <div class="swatches" role="radiogroup" aria-label="Backdrop">
          {#each BACKDROP_PRESETS as preset (preset)}
            {@const selectedPreset = sameFill(backdrop.fill, { kind: 'preset', preset })}
            <button
              type="button"
              role="radio"
              class="preset"
              class:selected={selectedPreset}
              aria-checked={selectedPreset}
              aria-label={presetTitle(preset)}
              title={presetTitle(preset)}
              style:--top={PRESET_COLORS[preset][0]}
              style:--bottom={PRESET_COLORS[preset][1]}
              onclick={() => session.updateBackdrop({ fill: { kind: 'preset', preset } })}
            ></button>
          {/each}
          <label class="custom" class:selected={backdrop.fill.kind === 'color'} title="Custom colour">
            <span class="visually-hidden">Custom backdrop colour</span>
            <input
              type="color"
              value={customBackdrop.slice(0, 7)}
              oninput={(e) =>
                session.updateBackdrop({ fill: { kind: 'color', color: e.currentTarget.value.toUpperCase() } }, true)}
            />
          </label>
        </div>
        <div class="slider-row">
          <div class="row"><span>Padding</span><span class="value tabular">{Math.round(backdrop.padding)}</span></div>
          <Slider
            label="Padding"
            min={0}
            max={160}
            value={backdrop.padding}
            oninput={(v) => session.updateBackdrop({ padding: v }, true)}
          />
        </div>
        <div class="slider-row">
          <div class="row"><span>Corners</span><span class="value tabular">{Math.round(backdrop.radius)}</span></div>
          <Slider
            label="Corners"
            min={0}
            max={32}
            value={backdrop.radius}
            oninput={(v) => session.updateBackdrop({ radius: v }, true)}
          />
        </div>
        <div class="row">
          <span>Shadow</span>
          <Toggle label="Shadow" checked={backdrop.shadow} onchange={(v) => session.updateBackdrop({ shadow: v })} />
        </div>
      {:else}
        <p class="hint">Puts the capture on a calm background with padding, for posts and docs.</p>
      {/if}
    </section>
  {/if}
</aside>

<style>
  .inspector {
    width: 272px;
    flex: none;
    overflow-y: auto;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 22px;
    background: var(--window);
    border-left: 1px solid var(--line);
  }
  section {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  h2 {
    margin: 0;
    font-size: 12px;
    font-weight: 600;
    color: var(--text-2);
  }
  .section-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    min-height: 26px;
    font-size: 12px;
  }
  .slider-row {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .slider-row .row {
    min-height: 0;
  }
  .control {
    flex: none;
  }
  .hint {
    margin: 0;
    font-size: 12px;
    color: var(--text-2);
  }
  .value {
    margin: 0;
    font-size: 12px;
    color: var(--text-2);
  }
  .buttons {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
  }
  .swatches {
    display: flex;
    align-items: center;
    gap: 4px;
  }
  .swatch,
  .preset,
  .custom {
    position: relative;
    flex: none;
    padding: 0;
    border: 0;
    background: none;
  }
  .swatch {
    width: 23px;
    height: 23px;
    border-radius: 50%;
  }
  .swatch::before {
    content: '';
    position: absolute;
    inset: 3px;
    border-radius: 50%;
    background: var(--swatch);
    box-shadow: inset 0 0 0 1px rgb(127 127 127 / 0.35);
  }
  .preset {
    width: 26px;
    height: 22px;
    border-radius: 6px;
  }
  .preset::before {
    content: '';
    position: absolute;
    inset: 2px;
    border-radius: 4px;
    background: linear-gradient(var(--top), var(--bottom));
    box-shadow: inset 0 0 0 1px rgb(127 127 127 / 0.3);
  }
  .swatch.selected,
  .custom.selected {
    box-shadow: 0 0 0 1.5px var(--text-1);
  }
  .preset.selected {
    box-shadow: 0 0 0 1.5px var(--text-1);
  }
  .custom {
    width: 30px;
    height: 23px;
    margin-left: 4px;
    border-radius: var(--r-control);
    overflow: hidden;
  }
  .custom input {
    position: absolute;
    inset: 2px;
    width: calc(100% - 4px);
    height: calc(100% - 4px);
    padding: 0;
    border: 0;
    border-radius: 3px;
    background: none;
  }
  .custom input::-webkit-color-swatch-wrapper {
    padding: 0;
  }
  .custom input::-webkit-color-swatch {
    border: 1px solid rgb(127 127 127 / 0.35);
    border-radius: 3px;
  }
</style>
