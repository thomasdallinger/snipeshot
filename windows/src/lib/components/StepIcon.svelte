<script lang="ts">
  // Lucide has no numbered circle; this draws one in the same 24-unit grid and stroke style.
  let { size = 16, strokeWidth = 1.75 }: { size?: number; strokeWidth?: number } = $props();
</script>

<svg
  xmlns="http://www.w3.org/2000/svg"
  width={size}
  height={size}
  viewBox="0 0 24 24"
  fill="none"
  stroke="currentColor"
  stroke-width={strokeWidth}
  stroke-linecap="round"
  stroke-linejoin="round"
  aria-hidden="true"
>
  <circle cx="12" cy="12" r="10" />
  <path d="M10.5 9.5 12.5 8v8" />
</svg>
