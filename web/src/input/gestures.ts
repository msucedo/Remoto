// Trackpad gesture recognizer. Pure logic: the view feeds pointer samples and
// the recognizer calls the sink with protocol-level intents.
import type { Action, MouseButton } from '../protocol/types';
import { ScrollPhase } from '../protocol/types';
import type { Timers } from '../net/timers';
import type { Direction, GestureMap } from '../store/settings';
import { PointerAccel, scrollFactor } from './accel';

export const G = {
  moveThreshold: 5,
  scrollThreshold: 7,
  secondTapRadius: 40,
  swipeThreshold: 38,
  pinchRatio: 0.14,
  pinchMaxCentroid: 21,
  zoomStep: 1.22,
  flingMin: 140,
  velocityWindow: 90,
  sampleFreshness: 55,
  history: 180,
  longPress: 450,
  tap1: 260,
  tap2: 364,
  tap34: 390,
  deferredClick: 260,
} as const;

export interface GestureSettings {
  pointerSpeed: number;
  pointerAcceleration: number;
  tapToClick: boolean;
  twoFingerTapRightClick: boolean;
  longPress: 'drag' | 'rightClick' | 'off';
  tapAndDrag: boolean;
  dragLock: boolean;
  scrollSpeed: number;
  naturalScroll: boolean;
  momentum: boolean;
  pinchToZoom: boolean;
  threeFinger: GestureMap;
  fourFinger: GestureMap;
}

export type Haptic = 'select' | 'light' | 'medium' | 'heavy' | 'error';

export interface TrackpadSink {
  touch(): void;
  move(dx: number, dy: number): void;
  scroll(phase: ScrollPhase, dx: number, dy: number): void;
  fling(vx: number, vy: number): void;
  button(button: MouseButton, op: 'down' | 'up'): void;
  click(button: MouseButton): void;
  zoom(dir: 1 | -1): void;
  action(a: Action): void;
  haptic(kind: Haptic): void;
  /** Real key-down for held modifiers, right before the first motion. */
  commitMods(): void;
}

interface Pt {
  x: number;
  y: number;
  sx: number;
  sy: number;
  lx: number;
  ly: number;
  lt: number;
}

type Phase = 'idle' | 'pending' | 'pointing' | 'dragging' | 'scrolling' | 'pinch' | 'done';

interface Sample {
  t: number;
  dx: number;
  dy: number;
}

/** Velocity in px/s from motion samples, per the trackpad rules. */
export function velocity(samples: readonly Sample[], now: number): [number, number] {
  const recent = samples.filter((s) => now - s.t <= G.velocityWindow);
  const last = recent[recent.length - 1];
  const first = recent[0];
  if (recent.length < 2 || !last || !first || now - last.t > G.sampleFreshness) return [0, 0];
  let dx = 0;
  let dy = 0;
  for (const s of recent) {
    dx += s.dx;
    dy += s.dy;
  }
  const dt = Math.max(16, last.t - first.t);
  return [(dx / dt) * 1000, (dy / dt) * 1000];
}

export class TrackpadGestures {
  private readonly pts = new Map<number, Pt>();
  private phase: Phase = 'idle';
  private primary = -1;
  private startT = 0;
  private maxPointers = 0;
  private secondTouch = false;
  private dragLocked = false;
  private deferred: { timer: number; x: number; y: number } | null = null;
  private longTimer: number | null = null;
  private samples: Sample[] = [];
  private baseCx = 0;
  private baseCy = 0;
  private baseSpread = 0;
  private zoomBase = 0;
  /** Where the tapping finger touched down (for the second-tap radius). */
  private lastUpX = 0;
  private lastUpY = 0;
  private readonly accel: PointerAccel;

  constructor(
    private readonly sink: TrackpadSink,
    private readonly settings: () => GestureSettings,
    private readonly timers: Timers,
  ) {
    this.accel = new PointerAccel(
      () => this.settings().pointerSpeed,
      () => this.settings().pointerAcceleration,
    );
  }

  get activePointers(): number {
    return this.pts.size;
  }

  get isDragLocked(): boolean {
    return this.dragLocked;
  }

  down(id: number, x: number, y: number, t: number): void {
    if (this.pts.has(id)) return;
    const s = this.settings();
    if (this.pts.size === 0) {
      this.sink.touch();
      this.accel.reset();
      this.startT = t;
      this.maxPointers = 1;
      this.primary = id;
      this.phase = 'pending';
      this.samples = [];
      this.secondTouch = false;
      if (this.deferred) {
        const near = Math.hypot(x - this.deferred.x, y - this.deferred.y) <= G.secondTapRadius;
        this.timers.clearTimeout(this.deferred.timer);
        this.deferred = null;
        if (near && !this.dragLocked) this.secondTouch = true;
        else this.sink.click('left');
      }
      this.pts.set(id, { x, y, sx: x, sy: y, lx: x, ly: y, lt: t });
      if (s.longPress !== 'off' && !this.dragLocked && !this.secondTouch) {
        this.longTimer = this.timers.setTimeout(() => this.longPressFired(), G.longPress);
      }
      return;
    }
    this.pts.set(id, { x, y, sx: x, sy: y, lx: x, ly: y, lt: t });
    this.maxPointers = Math.max(this.maxPointers, this.pts.size);
    this.cancelLongPress();
    if (this.phase === 'pending' || this.phase === 'pointing') {
      if (this.secondTouch) {
        this.sink.click('left');
        this.secondTouch = false;
      }
      this.phase = 'pending';
    }
    this.rebase();
  }

  move(id: number, x: number, y: number, t: number): void {
    const p = this.pts.get(id);
    if (!p) return;
    const dx = x - p.lx;
    const dy = y - p.ly;
    const dt = t - p.lt;
    p.x = x;
    p.y = y;
    const n = this.pts.size;
    const s = this.settings();

    switch (this.phase) {
      case 'pending':
        if (n === 1) {
          if (Math.hypot(x - p.sx, y - p.sy) > G.moveThreshold) {
            this.cancelLongPress();
            this.sink.commitMods();
            if (this.secondTouch) {
              this.secondTouch = false;
              this.sink.button('left', 'down');
              this.phase = 'dragging';
            } else if (this.dragLocked) {
              this.phase = 'dragging';
            } else {
              this.phase = 'pointing';
            }
            const tx = x - p.sx;
            const ty = y - p.sy;
            const [mx, my] = this.accel.apply(tx, ty, t - this.startT);
            this.sink.move(mx, my);
          }
        } else if (n === 2) {
          this.pendingTwo(s, t);
        } else {
          this.pendingMany(s);
        }
        break;
      case 'pointing':
      case 'dragging':
        if (id === this.primary && (dx !== 0 || dy !== 0)) {
          const [mx, my] = this.accel.apply(dx, dy, dt);
          this.sink.move(mx, my);
        }
        break;
      case 'scrolling': {
        const f = scrollFactor(s.scrollSpeed, s.naturalScroll);
        const cdx = dx / n;
        const cdy = dy / n;
        if (cdx !== 0 || cdy !== 0) {
          this.sink.scroll(ScrollPhase.Changed, cdx * f, cdy * f);
          this.addSample(t, cdx, cdy);
        }
        break;
      }
      case 'pinch': {
        const spread = this.spread();
        if (this.zoomBase > 0) {
          const r = spread / this.zoomBase;
          if (r >= G.zoomStep) {
            this.sink.zoom(1);
            this.sink.haptic('select');
            this.zoomBase = spread;
          } else if (r <= 1 / G.zoomStep) {
            this.sink.zoom(-1);
            this.sink.haptic('select');
            this.zoomBase = spread;
          }
        }
        break;
      }
      default:
        break;
    }
    p.lx = x;
    p.ly = y;
    p.lt = t;
  }

  up(id: number, t: number): void {
    if (!this.pts.has(id)) return;
    this.pts.delete(id);
    const s = this.settings();
    if (this.pts.size > 0) {
      if (this.phase === 'scrolling') {
        this.endScroll(s, t);
        this.phase = 'done';
      } else if (id === this.primary) {
        const next = this.pts.keys().next();
        if (!next.done) this.primary = next.value;
      }
      this.rebase();
      return;
    }
    this.cancelLongPress();
    const dur = t - this.startT;
    const phase = this.phase;
    this.phase = 'idle';

    if (phase === 'dragging') {
      if (s.dragLock) {
        if (!this.dragLocked) this.sink.haptic('light');
        this.dragLocked = true;
      } else {
        this.dragLocked = false;
        this.sink.button('left', 'up');
      }
      return;
    }
    if (phase === 'scrolling') {
      this.endScroll(s, t);
      return;
    }
    if (phase !== 'pending') return;

    if (this.dragLocked) {
      this.dragLocked = false;
      this.sink.button('left', 'up');
      return;
    }
    if (this.secondTouch) {
      this.secondTouch = false;
      this.sink.click('left');
      this.sink.click('left');
      return;
    }
    if (this.maxPointers === 1) {
      if (dur <= G.tap1 && s.tapToClick) {
        if (s.tapAndDrag) {
          const p0 = { x: this.lastUpX, y: this.lastUpY };
          const timer = this.timers.setTimeout(() => {
            this.deferred = null;
            this.sink.click('left');
          }, G.deferredClick);
          this.deferred = { timer, x: p0.x, y: p0.y };
        } else {
          this.sink.click('left');
        }
      }
    } else if (this.maxPointers === 2) {
      if (dur <= G.tap2 && s.twoFingerTapRightClick) this.sink.click('right');
    } else if (dur <= G.tap34) {
      const map = this.maxPointers >= 4 ? s.fourFinger : s.threeFinger;
      const a = map.tap;
      if (a) {
        this.sink.action(a);
        this.sink.haptic('light');
      }
    }
  }

  /** Lifts a pointer at its final position (preferred over `up`). */
  lift(id: number, x: number, y: number, t: number): void {
    const p = this.pts.get(id);
    if (p) this.move(id, x, y, t);
    if (this.pts.size === 1) {
      const only = this.pts.get(id);
      if (only) {
        this.lastUpX = only.sx;
        this.lastUpY = only.sy;
      }
    }
    this.up(id, t);
  }

  /** pointercancel, disconnect, page hidden or unmount. */
  cancel(): void {
    this.cancelLongPress();
    if (this.deferred) {
      this.timers.clearTimeout(this.deferred.timer);
      this.deferred = null;
    }
    if (this.phase === 'dragging' || this.dragLocked) this.sink.button('left', 'up');
    if (this.phase === 'scrolling') this.sink.scroll(ScrollPhase.Cancelled, 0, 0);
    this.dragLocked = false;
    this.secondTouch = false;
    this.pts.clear();
    this.phase = 'idle';
  }

  // ---- helpers ------------------------------------------------------------------

  private pendingTwo(s: GestureSettings, t: number): void {
    const [cx, cy] = this.centroid();
    const cdist = Math.hypot(cx - this.baseCx, cy - this.baseCy);
    const spread = this.spread();
    if (s.pinchToZoom && this.baseSpread > 0) {
      const ratio = spread / this.baseSpread;
      if (Math.abs(ratio - 1) > G.pinchRatio && cdist < G.pinchMaxCentroid) {
        this.phase = 'pinch';
        this.zoomBase = this.baseSpread;
        const r = spread / this.zoomBase;
        if (r >= G.zoomStep || r <= 1 / G.zoomStep) {
          this.sink.zoom(r >= G.zoomStep ? 1 : -1);
          this.sink.haptic('select');
          this.zoomBase = spread;
        }
        return;
      }
    }
    if (cdist > G.scrollThreshold) {
      this.sink.commitMods();
      this.phase = 'scrolling';
      const f = scrollFactor(s.scrollSpeed, s.naturalScroll);
      const ox = cx - this.baseCx;
      const oy = cy - this.baseCy;
      this.sink.scroll(ScrollPhase.Began, 0, 0);
      this.sink.scroll(ScrollPhase.Changed, ox * f, oy * f);
      this.samples = [{ t, dx: ox, dy: oy }];
    }
  }

  private pendingMany(s: GestureSettings): void {
    const [cx, cy] = this.centroid();
    const ox = cx - this.baseCx;
    const oy = cy - this.baseCy;
    if (Math.hypot(ox, oy) <= G.swipeThreshold) return;
    const dir: Direction = Math.abs(ox) > Math.abs(oy) ? (ox > 0 ? 'right' : 'left') : oy > 0 ? 'down' : 'up';
    const map = this.maxPointers >= 4 ? s.fourFinger : s.threeFinger;
    const a = map[dir];
    if (a) this.sink.action(a);
    this.sink.haptic('light');
    this.phase = 'done';
  }

  private endScroll(s: GestureSettings, t: number): void {
    this.sink.scroll(ScrollPhase.Ended, 0, 0);
    if (!s.momentum) return;
    const [vx, vy] = velocity(this.samples, t);
    if (Math.hypot(vx, vy) >= G.flingMin) {
      const f = scrollFactor(s.scrollSpeed, s.naturalScroll);
      this.sink.fling(vx * f, vy * f);
    }
    this.samples = [];
  }

  private addSample(t: number, dx: number, dy: number): void {
    this.samples.push({ t, dx, dy });
    while (this.samples.length > 0 && t - (this.samples[0]?.t ?? t) > G.history) this.samples.shift();
  }

  private centroid(): [number, number] {
    let x = 0;
    let y = 0;
    for (const p of this.pts.values()) {
      x += p.x;
      y += p.y;
    }
    const n = Math.max(1, this.pts.size);
    return [x / n, y / n];
  }

  private spread(): number {
    const [cx, cy] = this.centroid();
    let d = 0;
    for (const p of this.pts.values()) d += Math.hypot(p.x - cx, p.y - cy);
    return d / Math.max(1, this.pts.size);
  }

  private rebase(): void {
    const [cx, cy] = this.centroid();
    this.baseCx = cx;
    this.baseCy = cy;
    this.baseSpread = this.spread();
    this.zoomBase = this.baseSpread;
    for (const p of this.pts.values()) {
      p.sx = p.x;
      p.sy = p.y;
    }
  }

  private cancelLongPress(): void {
    if (this.longTimer !== null) this.timers.clearTimeout(this.longTimer);
    this.longTimer = null;
  }

  private longPressFired(): void {
    this.longTimer = null;
    if (this.phase !== 'pending' || this.pts.size !== 1) return;
    const s = this.settings();
    if (s.longPress === 'drag') {
      this.sink.commitMods();
      this.sink.button('left', 'down');
      this.sink.haptic('medium');
      this.phase = 'dragging';
      const p = this.pts.get(this.primary);
      if (p) {
        p.sx = p.x;
        p.sy = p.y;
      }
    } else if (s.longPress === 'rightClick') {
      this.sink.click('right');
      this.sink.haptic('medium');
      this.phase = 'done';
    }
  }
}
