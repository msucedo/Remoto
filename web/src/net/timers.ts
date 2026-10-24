// Injectable clock and timers so time-based logic can be tested.
export interface Timers {
  now(): number;
  setTimeout(fn: () => void, ms: number): number;
  clearTimeout(id: number): void;
}

export const realTimers: Timers = {
  now: () => performance.now(),
  setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms) as unknown as number,
  clearTimeout: (id) => globalThis.clearTimeout(id),
};

/** Deterministic timers for tests. */
export class FakeTimers implements Timers {
  private t = 0;
  private seq = 1;
  private readonly queue = new Map<number, { at: number; fn: () => void }>();

  now(): number {
    return this.t;
  }

  setTimeout(fn: () => void, ms: number): number {
    const id = this.seq++;
    this.queue.set(id, { at: this.t + Math.max(0, ms), fn });
    return id;
  }

  clearTimeout(id: number): void {
    this.queue.delete(id);
  }

  pending(): number {
    return this.queue.size;
  }

  /** Advances the clock, firing due timers in order. */
  advance(ms: number): void {
    const end = this.t + ms;
    for (;;) {
      let nextId = -1;
      let nextAt = Infinity;
      for (const [id, e] of this.queue) {
        if (e.at < nextAt || (e.at === nextAt && id < nextId)) {
          nextAt = e.at;
          nextId = id;
        }
      }
      if (nextId < 0 || nextAt > end) break;
      const e = this.queue.get(nextId);
      this.queue.delete(nextId);
      this.t = Math.max(this.t, nextAt);
      e?.fn();
    }
    this.t = end;
  }
}
