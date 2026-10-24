// Nearest-neighbour decimation to 16 kHz and Int16 conversion for dictation.

export const TARGET_RATE = 16000;
export const BLOCK_SAMPLES = 1600;

export function floatToInt16(s: number): number {
  const c = s > 1 ? 1 : s < -1 ? -1 : Number.isNaN(s) ? 0 : s;
  return c < 0 ? Math.round(c * 32768) : Math.round(c * 32767);
}

export interface PcmBlock {
  pcm: Int16Array;
  /** Peak absolute amplitude in the block, 0..1. */
  peak: number;
}

/**
 * Streams Float32 input at `inputRate` and emits blocks of 1600 Int16 samples
 * (100 ms at 16 kHz).
 */
export class Downsampler {
  private readonly rate: number;
  /** Output samples produced so far (rebased every second). */
  private k = 0;
  /** Input samples consumed before the current chunk (rebased with `k`). */
  private consumed = 0;
  private readonly block = new Int16Array(BLOCK_SAMPLES);
  private fill = 0;
  private peak = 0;

  constructor(
    inputRate: number,
    private readonly emit: (b: PcmBlock) => void,
    private readonly blockSize = BLOCK_SAMPLES,
  ) {
    this.rate = Math.round(inputRate);
    if (!(this.rate >= TARGET_RATE)) throw new RangeError('input rate must be at least 16 kHz');
  }

  /** Input index nearest to output sample `k`, computed exactly in integers. */
  private source(k: number): number {
    return Math.floor((2 * k * this.rate + TARGET_RATE) / (2 * TARGET_RATE));
  }

  push(input: Float32Array): void {
    const n = input.length;
    for (;;) {
      const idx = this.source(this.k) - this.consumed;
      if (idx >= n) break;
      const v = input[Math.max(0, idx)] ?? 0;
      const clipped = v > 1 ? 1 : v < -1 ? -1 : v;
      const a = Math.abs(clipped);
      if (a > this.peak) this.peak = a;
      this.block[this.fill++] = floatToInt16(clipped);
      if (this.fill >= this.blockSize) {
        this.emit({ pcm: this.block.slice(0, this.blockSize), peak: this.peak });
        this.fill = 0;
        this.peak = 0;
      }
      this.k++;
    }
    this.consumed += n;
    // Keep the counters small: one second of output maps to `rate` inputs.
    while (this.k >= TARGET_RATE && this.consumed >= this.rate) {
      this.k -= TARGET_RATE;
      this.consumed -= this.rate;
    }
  }

  /** Emits a partial block, if any. */
  flush(): void {
    if (this.fill === 0) return;
    this.emit({ pcm: this.block.slice(0, this.fill), peak: this.peak });
    this.fill = 0;
    this.peak = 0;
  }
}
