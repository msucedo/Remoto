// Coalesces pointer motion into binary frames, keeping move -> scroll order and
// respecting socket backpressure.
import { flingFrame, moveFrame, scrollFrame, touchFrame } from '../protocol/binary';
import { ScrollPhase } from '../protocol/types';
import type { Timers } from './timers';

export const FLUSH_INTERVAL_MS = 6;
export const BACKPRESSURE_BYTES = 65536;
export const BACKPRESSURE_RETRY_MS = 8;

export interface BinarySink {
  send(buf: ArrayBuffer): void;
  bufferedAmount(): number;
}

export class BinaryBatcher {
  private mx = 0;
  private my = 0;
  private sx = 0;
  private sy = 0;
  private phase: ScrollPhase | null = null;
  private timer: ReturnType<Timers['setTimeout']> | null = null;
  private lastFlush = -Infinity;

  constructor(
    private readonly sink: BinarySink,
    private readonly timers: Timers,
  ) {}

  move(dx: number, dy: number): void {
    if (!Number.isFinite(dx) || !Number.isFinite(dy)) return;
    this.mx += dx;
    this.my += dy;
    this.schedule();
  }

  scroll(phase: ScrollPhase, dx: number, dy: number): void {
    if (!Number.isFinite(dx) || !Number.isFinite(dy)) return;
    if (phase === ScrollPhase.Began) {
      this.flush(true);
      this.phase = ScrollPhase.Began;
      this.sx += dx;
      this.sy += dy;
      this.schedule();
      return;
    }
    if (phase === ScrollPhase.Ended || phase === ScrollPhase.Cancelled) {
      this.sx += dx;
      this.sy += dy;
      this.flush(true);
      this.sink.send(scrollFrame(phase, 0, 0));
      return;
    }
    if (this.phase === null) this.phase = phase;
    this.sx += dx;
    this.sy += dy;
    this.schedule();
  }

  fling(vx: number, vy: number): void {
    this.flush(true);
    this.sink.send(flingFrame(vx, vy));
  }

  touch(): void {
    this.flush(true);
    this.sink.send(touchFrame());
  }

  /** Sends whatever is accumulated. `force` ignores backpressure. */
  flush(force = false): void {
    if (this.timer !== null) {
      this.timers.clearTimeout(this.timer);
      this.timer = null;
    }
    if (!this.hasPending()) return;
    if (!force && this.sink.bufferedAmount() > BACKPRESSURE_BYTES) {
      this.timer = this.timers.setTimeout(() => {
        this.timer = null;
        this.flush(false);
      }, BACKPRESSURE_RETRY_MS);
      return;
    }
    this.lastFlush = this.timers.now();
    if (this.mx !== 0 || this.my !== 0) {
      this.sink.send(moveFrame(this.mx, this.my));
    }
    if (this.phase !== null) {
      // Scroll(None) only ever comes from wheel input; a gesture batch keeps its phase.
      this.sink.send(scrollFrame(this.phase, this.sx, this.sy));
    }
    this.mx = this.my = this.sx = this.sy = 0;
    this.phase = null;
  }

  /** Drops anything accumulated (the socket closed). */
  reset(): void {
    if (this.timer !== null) this.timers.clearTimeout(this.timer);
    this.timer = null;
    this.mx = this.my = this.sx = this.sy = 0;
    this.phase = null;
  }

  private hasPending(): boolean {
    return this.mx !== 0 || this.my !== 0 || this.phase !== null;
  }

  private schedule(): void {
    if (this.timer !== null) return;
    const wait = Math.max(0, this.lastFlush + FLUSH_INTERVAL_MS - this.timers.now());
    this.timer = this.timers.setTimeout(() => {
      this.timer = null;
      this.flush(false);
    }, wait);
  }
}
