<script lang="ts">
  import Button from '../../lib/components/Button.svelte';

  // A single problem line with one way to fix it.
  interface Props {
    text: string;
    button: string;
    onclick: () => void;
  }

  let { text, button, onclick }: Props = $props();
</script>

<div class="notice" role="status">
  <span class="dot" aria-hidden="true"></span>
  <span class="text">{text}</span>
  <Button size="small" {onclick}>{button}</Button>
</div>

<style>
  .notice {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 14px;
    border-radius: var(--r-card);
    border: 1px solid var(--control-stroke);
    background: var(--layer);
  }
  .notice + :global(.notice) {
    margin-top: 8px;
  }
  .dot {
    flex: none;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--caution);
  }
  .text {
    flex: 1;
    min-width: 0;
  }
</style>
