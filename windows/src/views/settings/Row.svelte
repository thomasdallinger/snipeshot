<script lang="ts">
  import type { Snippet } from 'svelte';

  // Label on the left, its control on the right. No icons next to labels (DESIGN.md).
  interface Props {
    label: string;
    children: Snippet;
  }

  let { label, children }: Props = $props();
</script>

<div class="row">
  <span class="label">{label}</span>
  <div class="control">{@render children()}</div>
</div>

<style>
  .row {
    display: flex;
    align-items: center;
    gap: 16px;
    min-height: 48px;
    padding: 8px 14px;
  }
  .label {
    flex: 1;
    min-width: 0;
  }
  .control {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    justify-content: flex-end;
  }
</style>
