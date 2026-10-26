<script lang="ts">
  import type { Snippet } from 'svelte';

  // A titled group of rows on one rounded layer, like a Windows 11 settings group.
  interface Props {
    title?: string;
    children: Snippet;
    footer?: Snippet;
  }

  let { title, children, footer }: Props = $props();
</script>

<section class="section">
  {#if title}<h2>{title}</h2>{/if}
  <div class="panel">
    {@render children()}
  </div>
  {#if footer}<div class="footer">{@render footer()}</div>{/if}
</section>

<style>
  .section + :global(.section) {
    margin-top: 16px;
  }
  h2 {
    margin: 0 0 6px 2px;
    font-size: 13px;
    font-weight: 600;
  }
  .panel {
    border-radius: var(--r-card);
    border: 1px solid var(--control-stroke);
    background: var(--layer);
  }
  .panel > :global(* + *) {
    border-top: 1px solid var(--line);
  }
  .footer {
    margin: 8px 2px 0;
    color: var(--text-2);
    font-size: 12px;
  }
</style>
