// Binary frames (client to server only), little-endian.
import type { ScrollPhase } from './types';

export const Frame = {
  Move: 0x01,
  Scroll: 0x02,
  Fling: 0x03,
  Touch: 0x04,
  Audio: 0x10,
} as const;

function f32Frame(type: number, a: number, b: number): ArrayBuffer {
  const buf = new ArrayBuffer(9);
  const v = new DataView(buf);
  v.setUint8(0, type);
  v.setFloat32(1, a, true);
  v.setFloat32(5, b, true);
  return buf;
}

export function moveFrame(dx: number, dy: number): ArrayBuffer {
  return f32Frame(Frame.Move, dx, dy);
}

export function flingFrame(vx: number, vy: number): ArrayBuffer {
  return f32Frame(Frame.Fling, vx, vy);
}

export function scrollFrame(phase: ScrollPhase, dx: number, dy: number): ArrayBuffer {
  const buf = new ArrayBuffer(10);
  const v = new DataView(buf);
  v.setUint8(0, Frame.Scroll);
  v.setUint8(1, phase);
  v.setFloat32(2, dx, true);
  v.setFloat32(6, dy, true);
  return buf;
}

export function touchFrame(): ArrayBuffer {
  return new Uint8Array([Frame.Touch]).buffer;
}

/** One audio frame: type byte followed by Int16 LE mono 16 kHz samples. */
export function audioFrame(pcm: Int16Array): ArrayBuffer {
  const buf = new ArrayBuffer(1 + pcm.length * 2);
  const v = new DataView(buf);
  v.setUint8(0, Frame.Audio);
  for (let i = 0; i < pcm.length; i++) v.setInt16(1 + i * 2, pcm[i] ?? 0, true);
  return buf;
}

export type DecodedFrame =
  | { type: 'move'; dx: number; dy: number }
  | { type: 'scroll'; phase: number; dx: number; dy: number }
  | { type: 'fling'; vx: number; vy: number }
  | { type: 'touch' }
  | { type: 'audio'; pcm: Int16Array };

/** Mirror of the server-side parser; used by tests and the mock server. */
export function decodeFrame(buf: ArrayBuffer): DecodedFrame | null {
  const v = new DataView(buf);
  if (buf.byteLength < 1) return null;
  const type = v.getUint8(0);
  const finite = (...n: number[]) => n.every(Number.isFinite);
  switch (type) {
    case Frame.Move:
    case Frame.Fling: {
      if (buf.byteLength !== 9) return null;
      const a = v.getFloat32(1, true);
      const b = v.getFloat32(5, true);
      if (!finite(a, b)) return null;
      return type === Frame.Move ? { type: 'move', dx: a, dy: b } : { type: 'fling', vx: a, vy: b };
    }
    case Frame.Scroll: {
      if (buf.byteLength !== 10) return null;
      const dx = v.getFloat32(2, true);
      const dy = v.getFloat32(6, true);
      if (!finite(dx, dy)) return null;
      return { type: 'scroll', phase: v.getUint8(1), dx, dy };
    }
    case Frame.Touch:
      return buf.byteLength === 1 ? { type: 'touch' } : null;
    case Frame.Audio: {
      if (buf.byteLength < 3 || buf.byteLength % 2 === 0) return null;
      const n = (buf.byteLength - 1) / 2;
      const pcm = new Int16Array(n);
      for (let i = 0; i < n; i++) pcm[i] = v.getInt16(1 + i * 2, true);
      return { type: 'audio', pcm };
    }
    default:
      return null;
  }
}
