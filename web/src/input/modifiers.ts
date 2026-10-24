// Sticky modifier keys shared by the modifier row, the Mac keyboard and the
// custom keyboards.
import type { Timers } from '../net/timers';

export const MODIFIERS = {
  cmd: { bit: 0x0001, code: 0x37, symbol: '⌘' },
  shift: { bit: 0x0002, code: 0x38, symbol: '⇧' },
  opt: { bit: 0x0004, code: 0x3a, symbol: '⌥' },
  ctrl: { bit: 0x0008, code: 0x3b, symbol: '⌃' },
  fn: { bit: 0x0010, code: 0x3f, symbol: 'fn' },
  rcmd: { bit: 0x0100, code: 0x36, symbol: '⌘' },
  rshift: { bit: 0x0200, code: 0x3c, symbol: '⇧' },
  ropt: { bit: 0x0400, code: 0x3d, symbol: '⌥' },
  rctrl: { bit: 0x0800, code: 0x3e, symbol: '⌃' },
} as const;
export type Modifier = keyof typeof MODIFIERS;
/** Display order for the status pill. */
export const MOD_ORDER: readonly Modifier[] = ['ctrl', 'rctrl', 'opt', 'ropt', 'shift', 'rshift', 'cmd', 'rcmd', 'fn'];

export const LATCH_MS = 320;
export const LOCK_MS = 380;

export type ModState = 'off' | 'latched' | 'locked' | 'held';

export interface ModSender {
  key(code: number, down: boolean): void;
}

interface Entry {
  state: ModState;
  /** State before the current press. */
  prior: ModState;
  downAt: number;
  used: boolean;
  /** A real key-down has been sent and not yet released. */
  realDown: boolean;
  lastTapAt: number;
}

export class ModifierMachine {
  private readonly entries = new Map<Modifier, Entry>();
  private readonly listeners = new Set<() => void>();

  constructor(
    private readonly sender: ModSender,
    private readonly timers: Timers,
  ) {}

  onChange(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  state(m: Modifier): ModState {
    return this.entries.get(m)?.state ?? 'off';
  }

  /** Any modifier that is not off. */
  active(): Modifier[] {
    return MOD_ORDER.filter((m) => this.state(m) !== 'off');
  }

  anyLocked(): boolean {
    return MOD_ORDER.some((m) => this.state(m) === 'locked');
  }

  /** Mods that change the meaning of the next key (for labels): every non-off modifier. */
  effectiveMask(): number {
    let mask = 0;
    for (const m of this.active()) mask |= MODIFIERS[m].bit;
    return mask;
  }

  press(m: Modifier): void {
    const e = this.entry(m);
    if (e.state === 'held') return;
    e.prior = e.state;
    e.state = 'held';
    e.downAt = this.timers.now();
    e.used = false;
    this.emit();
  }

  release(m: Modifier): void {
    const e = this.entries.get(m);
    if (!e || e.state !== 'held') return;
    const now = this.timers.now();
    const tap = !e.used && now - e.downAt <= LATCH_MS;
    if (e.used) {
      if (e.prior === 'locked' && m !== 'fn') {
        e.state = 'locked';
      } else {
        this.sendUp(m, e);
        e.state = e.prior === 'locked' ? 'locked' : 'off';
      }
    } else if (tap) {
      switch (e.prior) {
        case 'off':
          e.state = 'latched';
          e.lastTapAt = now;
          break;
        case 'latched':
          if (now - e.lastTapAt <= LOCK_MS) {
            e.state = 'locked';
            this.sendDown(m, e);
          } else {
            e.state = 'off';
          }
          break;
        case 'locked':
          e.state = 'off';
          this.sendUp(m, e);
          break;
        default:
          e.state = 'off';
      }
    } else {
      // Held for a while without using it: back to what it was.
      e.state = e.prior === 'held' ? 'off' : e.prior;
      if (e.state !== 'locked') this.sendUp(m, e);
    }
    this.emit();
  }

  /** Sends a real key-down for held modifiers that have not been sent yet. */
  commitHeld(): void {
    for (const [m, e] of this.entries) {
      if (e.state === 'held') {
        e.used = true;
        this.sendDown(m, e);
      }
    }
  }

  /**
   * Called right before an action (key, tap, click). Commits held modifiers,
   * returns the `mods` mask (latched plus locked Fn) and consumes the latched ones.
   */
  take(): number {
    this.commitHeld();
    let mask = 0;
    let changed = false;
    for (const [m, e] of this.entries) {
      if (e.state === 'latched') {
        mask |= MODIFIERS[m].bit;
        e.state = 'off';
        changed = true;
      } else if (e.state === 'locked' && m === 'fn') {
        mask |= MODIFIERS[m].bit;
      }
    }
    if (changed) this.emit();
    return mask;
  }

  /** Latched modifiers, without consuming them. */
  peekLatched(): number {
    let mask = 0;
    for (const [m, e] of this.entries) if (e.state === 'latched') mask |= MODIFIERS[m].bit;
    return mask;
  }

  /** Turns everything off and releases real key-downs. */
  releaseAll(): void {
    for (const [m, e] of this.entries) {
      this.sendUp(m, e);
      e.state = 'off';
    }
    this.emit();
  }

  /**
   * Page hidden or connection lost: release what the Mac holds but keep the
   * locked state so it can be restored.
   */
  suspend(): void {
    for (const [m, e] of this.entries) {
      this.sendUp(m, e);
      if (e.state !== 'locked') e.state = 'off';
    }
    this.emit();
  }

  /** Forget real key-downs without sending (the session is gone). */
  forgetRemote(): void {
    for (const e of this.entries.values()) e.realDown = false;
  }

  /** Re-press locked modifiers on the Mac (after welcome, visible, unpause). */
  restoreLocked(): void {
    for (const [m, e] of this.entries) {
      if (e.state === 'locked') {
        e.realDown = false;
        this.sendDown(m, e);
      }
    }
  }

  private entry(m: Modifier): Entry {
    let e = this.entries.get(m);
    if (!e) {
      e = { state: 'off', prior: 'off', downAt: 0, used: false, realDown: false, lastTapAt: -Infinity };
      this.entries.set(m, e);
    }
    return e;
  }

  private sendDown(m: Modifier, e: Entry): void {
    if (e.realDown || (m === 'fn' && e.state === 'locked')) return;
    e.realDown = true;
    this.sender.key(MODIFIERS[m].code, true);
  }

  private sendUp(m: Modifier, e: Entry): void {
    if (!e.realDown) return;
    e.realDown = false;
    this.sender.key(MODIFIERS[m].code, false);
  }

  private emit(): void {
    for (const fn of this.listeners) fn();
  }
}
