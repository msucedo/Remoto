// Vertical scroll rail beside the trackpad.
import { ScrollPhase } from '../protocol/types';
import type { Timers } from '../net/timers';
import { G, velocity } from './gestures';
import { scrollFactor } from './accel';

export interface StripSink {
  touch(): void;
  scroll(phase: ScrollPhase, dx: number, dy: number): void;
  fling(vx: number, vy: number): void;
}

export interface StripSettings {
  scrollSpeed: number;
  naturalScroll: boolean;
  momentum: boolean;
}

export const HOLD = { base: 360, perPx: 14, max: 2400, tick: 16, maxDt: 0.1 } as const;

export function holdSpeed(excess: number): number {
  return Math.sign(excess) * Math.min(HOLD.max, HOLD.base + Math.abs(excess) * HOLD.perPx);
}

export class ScrollStrip {
  private active = false;
  private started = false;
  private lastY = 0;
  private samples: { t: number; dx: number; dy: number }[] = [];
  private excess = 0;
  private held = false;
  private holdTimer: number | null = null;
  private holdLast = 0;

  constructor(
    private readonly sink: StripSink,
    private readonly settings: () => StripSettings,
    private readonly timers: Timers,
  ) {}

  get isActive(): boolean {
    return this.active;
  }

  down(y: number): void {
    this.active = true;
    this.started = false;
    this.held = false;
    this.lastY = y;
    this.samples = [];
    this.sink.touch();
  }

  move(y: number, t: number): void {
    if (!this.active) return;
    const dy = y - this.lastY;
    this.lastY = y;
    if (dy === 0) return;
    const s = this.settings();
    const f = scrollFactor(s.scrollSpeed, s.naturalScroll);
    if (!this.started) {
      this.started = true;
      this.sink.scroll(ScrollPhase.Began, 0, dy * f);
    } else {
      this.sink.scroll(ScrollPhase.Changed, 0, dy * f);
    }
    this.samples.push({ t, dx: 0, dy });
    while (this.samples.length && t - (this.samples[0]?.t ?? t) > G.history) this.samples.shift();
  }

  /** Signed distance the finger is past the end of a short rail (0 inside). */
  setOverflow(excess: number): void {
    if (!this.active) return;
    this.excess = excess;
    if (excess !== 0 && this.holdTimer === null) {
      this.held = true;
      this.holdLast = this.timers.now();
      this.holdTimer = this.timers.setTimeout(() => this.holdTick(), HOLD.tick);
    } else if (excess === 0) {
      this.stopHold();
    }
  }

  up(t: number): void {
    if (!this.active) return;
    this.active = false;
    this.stopHold();
    if (!this.started) return;
    this.sink.scroll(ScrollPhase.Ended, 0, 0);
    const s = this.settings();
    if (this.held || !s.momentum) return;
    const [, vy] = velocity(this.samples, t);
    if (Math.abs(vy) >= G.flingMin) this.sink.fling(0, vy * scrollFactor(s.scrollSpeed, s.naturalScroll));
  }

  cancel(): void {
    if (!this.active) return;
    this.active = false;
    this.stopHold();
    if (this.started) this.sink.scroll(ScrollPhase.Cancelled, 0, 0);
  }

  private stopHold(): void {
    if (this.holdTimer !== null) this.timers.clearTimeout(this.holdTimer);
    this.holdTimer = null;
    this.excess = 0;
  }

  private holdTick(): void {
    this.holdTimer = null;
    if (!this.active || this.excess === 0) return;
    const now = this.timers.now();
    const dt = Math.min(HOLD.maxDt, (now - this.holdLast) / 1000);
    this.holdLast = now;
    const s = this.settings();
    const dy = holdSpeed(this.excess) * dt;
    const f = scrollFactor(s.scrollSpeed, s.naturalScroll);
    if (!this.started) {
      this.started = true;
      this.sink.scroll(ScrollPhase.Began, 0, dy * f);
    } else {
      this.sink.scroll(ScrollPhase.Changed, 0, dy * f);
    }
    this.holdTimer = this.timers.setTimeout(() => this.holdTick(), HOLD.tick);
  }
}
