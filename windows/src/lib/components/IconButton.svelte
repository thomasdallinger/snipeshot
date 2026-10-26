<script lang="ts">
  import type { Snippet } from 'svelte';

  // Flat square button for chrome. The active state is a neutral fill, not the accent colour.
  interface Props {
    label: string;
    /** Tooltip; defaults to the label. */
    title?: string;
    active?: boolean;
    disabled?: boolean;
    /** Sits directly on a screenshot: white icon on its own dark plate. */
    onImage?: boolean;
    /** Inside the dark hover bar of a shelf card. */
    onDark?: boolean;
    size?: 'normal' | 'small';
    onclick?: (e: MouseEvent) => void;
    children: Snippet;
  }

  let {
    label,
    title,
    active = false,
    disabled = false,
    onImage = false,
    onDark = false,
    size = 'normal',
    onclick,
    children,
  }: Props = $props();
</script>

<button
  type="button"
  class="icon-button"
  class:active
  class:on-image={onImage}
  class:on-dark={onDark}
  class:small={size === 'small'}
  aria-label={label}
  aria-pressed={active ? true : undefined}
  title={title ?? label}
  {disabled}
  {onclick}
>
  {@render children()}
</button>

<style>
  .icon-button {
    display: inline-grid;
    place-items: center;
    flex: none;
    width: 32px;
    height: 32px;
    padding: 0;
    border: 0;
    border-radius: var(--r-control);
    background: transparent;
    color: var(--text-2);
  }
  .icon-button.small {
    width: 26px;
    height: 24px;
  }
  .icon-button:hover:not(:disabled) {
    background: var(--subtle-hover);
    color: var(--text-1);
  }
  .icon-button:active:not(:disabled) {
    background: var(--subtle-press);
  }
  .icon-button.active {
    background: var(--subtle-active);
    color: var(--text-1);
  }
  .icon-button:disabled {
    opacity: 0.35;
  }

  .on-image,
  .on-dark {
    color: rgb(255 255 255 / 0.88);
  }
  .on-image {
    background: rgb(0 0 0 / 0.6);
  }
  .on-image:hover:not(:disabled) {
    background: rgb(0 0 0 / 0.75);
    color: #fff;
  }
  .on-dark:hover:not(:disabled) {
    background: rgb(255 255 255 / 0.16);
    color: #fff;
  }
  .on-dark:active:not(:disabled),
  .on-image:active:not(:disabled) {
    background: rgb(255 255 255 / 0.1);
  }
</style>
