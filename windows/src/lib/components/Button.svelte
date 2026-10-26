<script lang="ts">
  import type { Snippet } from 'svelte';

  // Windows 11 standard button; `primary` is the one accent button of a surface.
  interface Props {
    variant?: 'standard' | 'primary' | 'danger';
    size?: 'normal' | 'small';
    title?: string;
    disabled?: boolean;
    onclick?: (e: MouseEvent) => void;
    children: Snippet;
  }

  let { variant = 'standard', size = 'normal', title, disabled = false, onclick, children }: Props = $props();
</script>

<button
  type="button"
  class="button {variant}"
  class:small={size === 'small'}
  {title}
  {disabled}
  {onclick}
>
  {@render children()}
</button>

<style>
  .button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    flex: none;
    height: 32px;
    padding: 0 12px;
    min-width: 64px;
    border-radius: var(--r-control);
    border: 1px solid var(--control-stroke);
    border-bottom-color: var(--control-stroke-bottom);
    background: var(--control);
    color: var(--text-1);
    white-space: nowrap;
  }
  .button.small {
    height: 26px;
    padding: 0 10px;
    min-width: 0;
    font-size: 12px;
  }
  .button:hover:not(:disabled) {
    background: var(--control-hover);
  }
  .button:active:not(:disabled) {
    background: var(--control-press);
    color: var(--text-2);
  }
  .button:disabled {
    opacity: 0.45;
  }

  .primary {
    background: var(--accent);
    color: var(--accent-ink);
    border-color: color-mix(in srgb, var(--accent) 85%, white);
    border-bottom-color: color-mix(in srgb, var(--accent) 70%, black);
  }
  .primary:hover:not(:disabled) {
    background: color-mix(in srgb, var(--accent) 90%, var(--window));
  }
  .primary:active:not(:disabled) {
    background: color-mix(in srgb, var(--accent) 80%, var(--window));
    color: var(--accent-ink);
  }

  .danger {
    color: var(--critical);
  }
</style>
