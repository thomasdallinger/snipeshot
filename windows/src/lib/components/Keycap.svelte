<script lang="ts">
  let { text }: { text: string } = $props();
</script>

<kbd>{text}</kbd>

<style>
  kbd {
    display: inline-block;
    padding: 1px 6px;
    border-radius: var(--r-control);
    border: 1px solid var(--control-stroke);
    border-bottom-color: var(--control-stroke-bottom);
    background: var(--control);
    font-family: var(--font-ui);
    font-size: 12px;
    font-weight: 600;
    color: var(--text-1);
  }
</style>
