// Pointer acceleration curve applied on the phone before sending Move frames.

const softplus = (x: number, k: number): number => k * Math.log1p(Math.exp(x / k));

export class PointerAccel {
  private s = -1;

  constructor(
    private speed: () => number,
    private acceleration: () => number,
  ) {}

  /** Restarts the speed smoothing (on every new touch). */
  reset(): void {
    this.s = -1;
  }

  /** Gain for a delta that took `dtMs` milliseconds. */
  gain(dx: number, dy: number, dtMs: number): number {
    const dt = Math.max(1, dtMs);
    const v = Math.hypot(dx, dy) / dt;
    const speed = this.speed();
    const acc = this.acceleration();
    const tau = 25 + 15 * Math.min(1, Math.max(0, (speed - 1) / 3));
    this.s = this.s < 0 ? v : this.s + (v - this.s) * (1 - Math.exp(-dt / tau));
    const z = Math.max(0, 2.2 - softplus(2.2 - softplus((this.s - 0.08) / 0.9, 0.03), 0.1));
    return speed * (0.8 + acc * z * 1.4 + (1 - acc) * 0.25);
  }

  apply(dx: number, dy: number, dtMs: number): [number, number] {
    const g = this.gain(dx, dy, dtMs);
    return [dx * g, dy * g];
  }
}

/** Factor for scroll deltas and fling velocities. */
export function scrollFactor(scrollSpeed: number, natural: boolean): number {
  return scrollSpeed * 1.6 * (natural ? 1 : -1);
}
