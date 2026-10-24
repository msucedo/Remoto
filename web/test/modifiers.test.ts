import { beforeEach, describe, expect, it } from 'vitest';
import { ModifierMachine } from '../src/input/modifiers';
import { FakeTimers } from '../src/net/timers';

let timers: FakeTimers;
let sent: [number, boolean][];
let m: ModifierMachine;

beforeEach(() => {
  timers = new FakeTimers();
  sent = [];
  m = new ModifierMachine({ key: (code, down) => sent.push([code, down]) }, timers);
});

const tap = (mod: Parameters<ModifierMachine['press']>[0], hold = 50) => {
  m.press(mod);
  timers.advance(hold);
  m.release(mod);
};

describe('sticky modifiers', () => {
  it('a quick tap latches for one action', () => {
    tap('cmd');
    expect(m.state('cmd')).toBe('latched');
    expect(sent).toEqual([]);
    expect(m.take()).toBe(0x01);
    expect(m.state('cmd')).toBe('off');
    expect(m.take()).toBe(0);
  });

  it('a second tap within 380 ms locks with a real key-down', () => {
    tap('shift');
    timers.advance(200);
    tap('shift');
    expect(m.state('shift')).toBe('locked');
    expect(sent).toEqual([[0x38, true]]);
    // Locked (non-Fn) modifiers are not in the mask; the Mac holds them.
    expect(m.take()).toBe(0);
    tap('shift');
    expect(m.state('shift')).toBe('off');
    expect(sent.at(-1)).toEqual([0x38, false]);
  });

  it('a slow second tap turns a latched modifier off', () => {
    tap('opt');
    timers.advance(600);
    tap('opt');
    expect(m.state('opt')).toBe('off');
  });

  it('a long press without use is not a tap', () => {
    tap('ctrl', 400);
    expect(m.state('ctrl')).toBe('off');
    expect(sent).toEqual([]);
  });

  it('held modifiers send key-down just before the first action and key-up on release', () => {
    m.press('cmd');
    expect(sent).toEqual([]);
    expect(m.take()).toBe(0);
    expect(sent).toEqual([[0x37, true]]);
    m.release('cmd');
    expect(sent).toEqual([
      [0x37, true],
      [0x37, false],
    ]);
    expect(m.state('cmd')).toBe('off');
  });

  it('commitHeld does not consume latched modifiers', () => {
    tap('cmd');
    m.press('shift');
    m.commitHeld();
    expect(sent).toEqual([[0x38, true]]);
    expect(m.state('cmd')).toBe('latched');
  });

  it('locked Fn goes in the mask and never as a real key', () => {
    tap('fn');
    timers.advance(100);
    tap('fn');
    expect(m.state('fn')).toBe('locked');
    expect(sent).toEqual([]);
    expect(m.take()).toBe(0x10);
    expect(m.take()).toBe(0x10);
  });

  it('right modifiers use right bits and codes', () => {
    tap('rshift');
    expect(m.take()).toBe(0x200);
    tap('rcmd');
    timers.advance(100);
    tap('rcmd');
    expect(sent).toEqual([[0x36, true]]);
  });

  it('suspend releases on the Mac but keeps locks for restore', () => {
    tap('cmd');
    timers.advance(100);
    tap('cmd');
    tap('opt');
    sent.length = 0;
    m.suspend();
    expect(sent).toEqual([[0x37, false]]);
    expect(m.state('cmd')).toBe('locked');
    expect(m.state('opt')).toBe('off');
    m.restoreLocked();
    expect(sent.at(-1)).toEqual([0x37, true]);
  });

  it('releaseAll turns everything off', () => {
    tap('ctrl');
    timers.advance(100);
    tap('ctrl');
    tap('shift');
    m.releaseAll();
    expect(m.active()).toEqual([]);
    expect(sent.at(-1)).toEqual([0x3b, false]);
  });

  it('notifies listeners', () => {
    let n = 0;
    m.onChange(() => n++);
    tap('cmd');
    expect(n).toBeGreaterThan(0);
  });
});
