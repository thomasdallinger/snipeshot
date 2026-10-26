// The capture sound, synthesized from a short list of voices so macOS and Windows play the same file.
//
//   node scripts/sounds.mjs   # writes assets/sounds/capture.wav

export const RATE = 48_000;
/** Each voice keeps running this long after its decay before it is cut. */
const TAIL = 0.02;

/**
 * Voices:
 *   { kind: 'tone', t, f0, f1, glide, dur, gain, attack, wave: 'sine' | 'triangle' }
 *     Frequency glides exponentially from f0 to f1 over `glide` s; level rises linearly to `gain` over
 *     `attack`, then decays exponentially to silence at `dur` (all relative to the start time `t`).
 *   { kind: 'noise', t, dur, gain, attack, band: [lowHz, highHz] }
 *     White noise through a band-pass, same envelope. A fixed seed keeps the output identical every run.
 */
const tone = (t, f0, f1, glide, dur, gain, attack = 0.002, wave = 'sine') => ({ kind: 'tone', t, f0, f1, glide, dur, gain, attack, wave });
const noise = (t, dur, gain, band, attack = 0.001) => ({ kind: 'noise', t, dur, gain, attack, band });

/** Mirror snap: a crisp snap over a low thump, then a softer second click, like an SLR mirror. */
export const CAPTURE = [
  noise(0, 0.025, 0.7, [2500, 7000]),
  tone(0, 140, 70, 0.03, 0.09, 0.5, 0.001),
  noise(0.05, 0.03, 0.35, [900, 3000]),
];

/** Deterministic PRNG (mulberry32) so the noise, and with it the file, never changes. */
function random(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** RBJ band-pass biquad (constant 0 dB peak gain) centred between the band edges. */
function bandPass(low, high) {
  const centre = Math.sqrt(low * high);
  const q = centre / (high - low);
  const w = (2 * Math.PI * centre) / RATE;
  const alpha = Math.sin(w) / (2 * q);
  const a0 = 1 + alpha;
  const b0 = alpha / a0, b2 = -alpha / a0, a1 = (-2 * Math.cos(w)) / a0, a2 = (1 - alpha) / a0;
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  return (x) => {
    const y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}

function envelope(v, t) {
  if (t < v.attack) return (v.gain * t) / v.attack;
  if (t <= v.dur) return v.gain * Math.pow(1e-4 / v.gain, (t - v.attack) / (v.dur - v.attack));
  return 0;
}

/** Mono samples in [-1, 1], normalised to `peak`. */
export function render(voices, peak = 0.6) {
  const length = Math.max(...voices.map((v) => v.t + v.dur + TAIL));
  const out = new Float32Array(Math.ceil(length * RATE));
  voices.forEach((v, index) => {
    const first = Math.round(v.t * RATE);
    const count = Math.round((v.dur + TAIL) * RATE);
    if (v.kind === 'tone') {
      let phase = 0;
      for (let i = 0; i < count && first + i < out.length; i++) {
        const t = i / RATE;
        const f = v.glide > 0 && t < v.glide ? v.f0 * Math.pow(v.f1 / v.f0, t / v.glide) : v.f1;
        const wave = v.wave === 'triangle' ? (2 / Math.PI) * Math.asin(Math.sin(phase)) : Math.sin(phase);
        out[first + i] += wave * envelope(v, t);
        phase = (phase + (2 * Math.PI * f) / RATE) % (2 * Math.PI);
      }
    } else {
      const next = random(0x5eed + index);
      const filter = bandPass(v.band[0], v.band[1]);
      for (let i = 0; i < count && first + i < out.length; i++) {
        out[first + i] += filter(next() * 2 - 1) * 3 * envelope(v, i / RATE);
      }
    }
  });
  let max = 0;
  for (const s of out) max = Math.max(max, Math.abs(s));
  if (max > 0) for (let i = 0; i < out.length; i++) out[i] *= peak / max;
  // A 2 ms fade at the end so the cut never clicks.
  const fade = Math.round(0.002 * RATE);
  for (let i = 0; i < fade; i++) out[out.length - 1 - i] *= i / fade;
  return out;
}

/** 16-bit mono PCM WAV. */
export function encodeWav(samples) {
  const dataLength = samples.length * 2;
  const view = new DataView(new ArrayBuffer(44 + dataLength));
  const text = (offset, s) => [...s].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)));
  text(0, 'RIFF');
  view.setUint32(4, 36 + dataLength, true);
  text(8, 'WAVEfmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, RATE, true);
  view.setUint32(28, RATE * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  text(36, 'data');
  view.setUint32(40, dataLength, true);
  samples.forEach((s, i) => view.setInt16(44 + i * 2, Math.round(Math.max(-1, Math.min(1, s)) * 32767), true));
  return new Uint8Array(view.buffer);
}

if (typeof process !== 'undefined' && import.meta.url === `file://${process.argv[1]}`) {
  const { writeFileSync, mkdirSync } = await import('node:fs');
  const { dirname, join } = await import('node:path');
  const out = join(dirname(new URL(import.meta.url).pathname), '..', 'assets', 'sounds', 'capture.wav');
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, encodeWav(render(CAPTURE)));
  console.log(`wrote ${out}`);
}
