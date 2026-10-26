<script lang="ts" generics="T extends string">
  // Native select dressed as a Windows 11 combo box.
  interface Props {
    options: { value: T; label: string }[];
    value: T;
    label: string;
    onchange: (value: T) => void;
  }

  let { options, value, label, onchange }: Props = $props();
</script>

<select class="select" aria-label={label} {value} onchange={(e) => onchange(e.currentTarget.value as T)}>
  {#each options as option (option.value)}
    <option value={option.value}>{option.label}</option>
  {/each}
</select>

<style>
  .select {
    height: 32px;
    min-width: 140px;
    padding: 0 30px 0 10px;
    border-radius: var(--r-control);
    border: 1px solid var(--control-stroke);
    border-bottom-color: var(--control-stroke-bottom);
    background-color: var(--control);
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24' fill='none' stroke='%23888' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='m6 9 6 6 6-6'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 10px center;
  }
  .select:hover {
    background-color: var(--control-hover);
  }
  option {
    background: var(--layer);
    color: var(--text-1);
  }
</style>
