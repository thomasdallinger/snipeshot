<script lang="ts">
  // Windows 11 toggle switch. The label is for assistive tech; the visible label sits next to it.
  interface Props {
    checked: boolean;
    label: string;
    disabled?: boolean;
    onchange: (checked: boolean) => void;
  }

  let { checked, label, disabled = false, onchange }: Props = $props();
</script>

<button
  type="button"
  role="switch"
  class="toggle"
  class:on={checked}
  aria-checked={checked}
  aria-label={label}
  {disabled}
  onclick={() => onchange(!checked)}
>
  <span class="knob"></span>
</button>

<style>
  .toggle {
    position: relative;
    flex: none;
    width: 40px;
    height: 20px;
    padding: 0;
    border-radius: 10px;
    border: 1px solid var(--text-2);
    background: var(--control);
  }
  .toggle:hover:not(:disabled) {
    background: var(--subtle-hover);
  }
  .knob {
    position: absolute;
    top: 50%;
    left: 4px;
    width: 12px;
    height: 12px;
    border-radius: 50%;
    background: var(--text-2);
    transform: translateY(-50%);
    transition:
      left var(--dur) var(--ease),
      width var(--dur) var(--ease);
  }
  .toggle:hover:not(:disabled) .knob {
    width: 14px;
    height: 14px;
  }
  .on {
    background: var(--accent);
    border-color: var(--accent);
  }
  .on:hover:not(:disabled) {
    background: color-mix(in srgb, var(--accent) 90%, var(--window));
  }
  .on .knob {
    left: 22px;
    background: var(--accent-ink);
  }
  .on:hover:not(:disabled) .knob {
    left: 21px;
  }
  .toggle:disabled {
    opacity: 0.45;
  }
</style>
