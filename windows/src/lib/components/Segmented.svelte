<script lang="ts" generics="T extends string | number">
  // A row of mutually exclusive options (stroke presets, redaction style).
  interface Props {
    options: { value: T; label: string; title?: string }[];
    value: T;
    label: string;
    onchange: (value: T) => void;
  }

  let { options, value, label, onchange }: Props = $props();
</script>

<div class="segmented" role="radiogroup" aria-label={label}>
  {#each options as option (option.value)}
    <button
      type="button"
      role="radio"
      aria-checked={option.value === value}
      class:selected={option.value === value}
      title={option.title}
      onclick={() => onchange(option.value)}
    >
      {option.label}
    </button>
  {/each}
</div>

<style>
  .segmented {
    display: flex;
    gap: 2px;
    padding: 2px;
    border-radius: var(--r-control);
    background: var(--subtle-hover);
    border: 1px solid var(--control-stroke);
  }
  button {
    flex: 1;
    min-width: 28px;
    height: 24px;
    padding: 0 8px;
    border: 0;
    border-radius: 3px;
    background: transparent;
    color: var(--text-2);
    font-size: 12px;
    white-space: nowrap;
  }
  button:hover:not(.selected) {
    background: var(--subtle-hover);
    color: var(--text-1);
  }
  .selected {
    background: var(--layer);
    color: var(--text-1);
    font-weight: 600;
    box-shadow: 0 0 0 1px var(--control-stroke), 0 1px 1px var(--control-stroke-bottom);
  }
</style>
