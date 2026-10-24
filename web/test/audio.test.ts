import { describe, expect, it } from 'vitest';
import { BLOCK_SAMPLES, Downsampler, floatToInt16, type PcmBlock } from '../src/voice/downsample';

function run(rate: number, input: Float32Array, chunk = 128): PcmBlock[] {
  const blocks: PcmBlock[] = [];
  const ds = new Downsampler(rate, (b) => blocks.push(b));
  for (let i = 0; i < input.length; i += chunk) ds.push(input.subarray(i, i + chunk));
  return blocks;
}

describe('float to Int16', () => {
  it('scales asymmetrically and clips', () => {
    expect(floatToInt16(1)).toBe(32767);
    expect(floatToInt16(-1)).toBe(-32768);
    expect(floatToInt16(2)).toBe(32767);
    expect(floatToInt16(-3)).toBe(-32768);
    expect(floatToInt16(0)).toBe(0);
    expect(floatToInt16(0.5)).toBe(16384);
    expect(floatToInt16(Number.NaN)).toBe(0);
  });
});

describe('downsampler', () => {
  it('48 kHz -> one block of 1600 per 4800 input samples', () => {
    const blocks = run(48000, new Float32Array(48000));
    expect(blocks).toHaveLength(10);
    expect(blocks[0]?.pcm.length).toBe(BLOCK_SAMPLES);
  });

  it('44.1 kHz produces 16000 samples per second (±1)', () => {
    const blocks: PcmBlock[] = [];
    const ds = new Downsampler(44100, (b) => blocks.push(b));
    const input = new Float32Array(44100);
    for (let i = 0; i < input.length; i += 128) ds.push(input.subarray(i, i + 128));
    ds.flush();
    const total = blocks.reduce((n, b) => n + b.pcm.length, 0);
    expect(Math.abs(total - 16000)).toBeLessThanOrEqual(1);
  });

  it('picks the nearest input sample (decimation, not averaging)', () => {
    const input = new Float32Array(4800 * 3);
    for (let i = 0; i < input.length; i++) input[i] = (i % 3) / 4; // 0, 0.25, 0.5 repeating
    const blocks = run(48000, input, 480);
    // Step is 3, so every output sample comes from an index divisible by 3.
    expect(new Set(blocks[0]?.pcm)).toEqual(new Set([0]));
  });

  it('is independent of chunk boundaries', () => {
    const input = new Float32Array(9600);
    for (let i = 0; i < input.length; i++) input[i] = Math.sin(i / 7);
    const a = run(44100, input, 128).flatMap((b) => Array.from(b.pcm));
    const b = run(44100, input, 333).flatMap((b) => Array.from(b.pcm));
    expect(a).toEqual(b);
  });

  it('reports the block peak and clips out-of-range input', () => {
    const input = new Float32Array(4800).fill(0.1);
    input[300] = -1.7;
    const blocks = run(48000, input, 4800);
    expect(blocks[0]?.peak).toBe(1);
    expect(Math.min(...(blocks[0]?.pcm ?? []))).toBe(-32768);
  });

  it('16 kHz input passes through unchanged', () => {
    const input = new Float32Array(1600).map((_, i) => (i % 2 ? 0.5 : -0.5));
    const blocks = run(16000, input, 160);
    expect(blocks[0]?.pcm[0]).toBe(-16384);
    expect(blocks[0]?.pcm[1]).toBe(16384);
  });

  it('rejects rates below 16 kHz', () => {
    expect(() => new Downsampler(8000, () => undefined)).toThrow();
  });
});
