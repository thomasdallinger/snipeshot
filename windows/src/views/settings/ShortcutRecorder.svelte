<script lang="ts">
  import { onDestroy } from 'svelte';
  import { formatAccelerator, recordKey } from '../../lib/accelerator';
  import { api } from '../../lib/api';
  import type { Accelerator } from '../../lib/types';

  // Click, then type a key combination. Global shortcuts pause while recording so the keys reach us.
  interface Props {
    value: Accelerator | null;
    label: string;
    onchange: (value: Accelerator | null) => void;
    onrecording?: (recording: boolean) => void;
  }

  let { value, label, onchange, onrecording }: Props = $props();

  let recording = $state(false);
  let rejected = $state(false);
  let button = $state<HTMLButtonElement>();
  let rejectTimer: ReturnType<typeof setTimeout> | undefined;

  function start() {
    if (recording) return;
    recording = true;
    onrecording?.(true);
    void api.pauseShortcuts();
    // Capture phase so the settings window's own Esc handling never sees these keys.
    window.addEventListener('keydown', onKey, true);
    window.addEventListener('keyup', onKey, true);
    window.addEventListener('pointerdown', onPointer, true);
    window.addEventListener('blur', stop);
  }

  function stop() {
    if (!recording) return;
    recording = false;
    window.removeEventListener('keydown', onKey, true);
    window.removeEventListener('keyup', onKey, true);
    window.removeEventListener('pointerdown', onPointer, true);
    window.removeEventListener('blur', stop);
    void api.resumeShortcuts();
    onrecording?.(false);
  }

  function onKey(e: KeyboardEvent) {
    e.preventDefault();
    e.stopPropagation();
    const result = recordKey(e);
    switch (result.kind) {
      case 'set':
        stop();
        onchange(result.accelerator);
        break;
      case 'clear':
        stop();
        onchange(null);
        break;
      case 'cancel':
        stop();
        break;
      case 'invalid':
        // Like NSSound.beep(): the keys can't be a global shortcut; keep listening.
        rejected = true;
        clearTimeout(rejectTimer);
        rejectTimer = setTimeout(() => (rejected = false), 400);
        break;
      case 'ignore':
        break;
    }
  }

  function onPointer(e: PointerEvent) {
    if (button && !button.contains(e.target as Node)) stop();
  }

  onDestroy(() => {
    clearTimeout(rejectTimer);
    stop();
  });
</script>

<button
  bind:this={button}
  type="button"
  class="recorder tabular"
  class:recording
  class:rejected
  class:none={!value}
  aria-label="{label} shortcut"
  aria-live="polite"
  onclick={() => (recording ? stop() : start())}
>
  {recording ? 'Type shortcut' : value ? formatAccelerator(value) : 'None'}
</button>

<style>
  .recorder {
    min-width: 150px;
    height: 32px;
    padding: 0 12px;
    border-radius: var(--r-control);
    border: 1px solid var(--control-stroke);
    border-bottom-color: var(--control-stroke-bottom);
    background: var(--control);
    font-weight: 600;
    font-size: 12px;
  }
  .recorder:hover {
    background: var(--control-hover);
  }
  .none {
    color: var(--text-2);
    font-weight: 400;
  }
  .recording {
    color: var(--accent-text);
    border-color: var(--accent);
    font-weight: 400;
  }
  .rejected {
    animation: shake 0.3s var(--ease);
  }
  @keyframes shake {
    25% {
      transform: translateX(-3px);
    }
    75% {
      transform: translateX(3px);
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .rejected {
      animation: none;
      border-color: var(--critical);
    }
  }
</style>
