<script lang="ts">
  // Native range input styled like the Windows 11 slider. `oninput` fires while dragging.
  interface Props {
    value: number;
    min: number;
    max: number;
    step?: number;
    label: string;
    oninput: (value: number) => void;
  }

  let { value, min, max, step = 1, label, oninput }: Props = $props();

  const percent = $derived(((value - min) / (max - min)) * 100);
</script>

<input
  type="range"
  class="slider"
  {min}
  {max}
  {step}
  {value}
  aria-label={label}
  style:--fill="{percent}%"
  oninput={(e) => oninput(Number(e.currentTarget.value))}
/>

<style>
  .slider {
    -webkit-appearance: none;
    appearance: none;
    width: 100%;
    height: 20px;
    margin: 0;
    background: transparent;
  }
  .slider::-webkit-slider-runnable-track {
    height: 4px;
    border-radius: 2px;
    background: linear-gradient(to right, var(--accent) var(--fill), var(--track) var(--fill));
  }
  .slider::-webkit-slider-thumb {
    -webkit-appearance: none;
    width: 18px;
    height: 18px;
    margin-top: -7px;
    border-radius: 50%;
    background: var(--accent);
    border: 4px solid var(--layer);
    box-shadow: 0 0 0 1px var(--control-stroke-bottom);
    transition: border-width var(--dur) var(--ease);
  }
  .slider:hover::-webkit-slider-thumb {
    border-width: 3px;
  }
  .slider:active::-webkit-slider-thumb {
    border-width: 5px;
  }
</style>
