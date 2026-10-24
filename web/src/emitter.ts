// Typed event emitter.
export class Emitter<Events extends Record<string, unknown>> {
  private readonly map = new Map<keyof Events, Set<(v: never) => void>>();

  on<K extends keyof Events>(type: K, fn: (v: Events[K]) => void): () => void {
    let set = this.map.get(type);
    if (!set) {
      set = new Set();
      this.map.set(type, set);
    }
    set.add(fn as (v: never) => void);
    return () => set.delete(fn as (v: never) => void);
  }

  emit<K extends keyof Events>(type: K, value: Events[K]): void {
    const set = this.map.get(type);
    if (!set) return;
    for (const fn of [...set]) {
      try {
        (fn as (v: Events[K]) => void)(value);
      } catch (err) {
        console.error(err);
      }
    }
  }
}
