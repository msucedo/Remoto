import { beforeEach, describe, expect, it } from 'vitest';
import { PointerAccel, scrollFactor } from '../src/input/accel';
import { TrackpadGestures, velocity, type GestureSettings, type TrackpadSink } from '../src/input/gestures';
import { holdSpeed, ScrollStrip } from '../src/input/strip';
import { FakeTimers } from '../src/net/timers';
import { defaultSettings } from '../src/store/settings';

type Call = [string, ...unknown[]];

function recorder(): TrackpadSink & { calls: Call[]; names(): string[] } {
  const calls: Call[] = [];
  const rec = (name: string) => (...a: unknown[]) => void calls.push([name, ...a]);
  return {
    calls,
    names: () => calls.map((c) => c[0]),
    touch: rec('touch'),
    move: rec('move'),
    scroll: rec('scroll'),
    fling: rec('fling'),
    button: rec('button'),
    click: rec('click'),
    zoom: rec('zoom'),
    action: rec('action'),
    haptic: rec('haptic'),
    commitMods: rec('commitMods'),
  };
}

describe('acceleration', () => {
  it('slow motion gets a gain close to speed * (0.8 + base)', () => {
    const acc = new PointerAccel(() => 1, () => 0);
    expect(acc.gain(1, 0, 16)).toBeCloseTo(1.05, 5);
  });
  it('fast motion gains more than slow motion with acceleration on', () => {
    const slow = new PointerAccel(() => 1.2, () => 0.6);
    const fast = new PointerAccel(() => 1.2, () => 0.6);
    const gs = slow.gain(1, 0, 16);
    const gf = fast.gain(40, 0, 16);
    expect(gf).toBeGreaterThan(gs);
    expect(gf).toBeLessThanOrEqual(1.2 * (0.8 + 0.6 * 2.2 * 1.4 + 0.4 * 0.25) + 1e-9);
  });
  it('smooths speed and resets on touch', () => {
    const a = new PointerAccel(() => 1, () => 1);
    const first = a.gain(30, 0, 10);
    const after = a.gain(0.5, 0, 10);
    expect(after).toBeLessThan(first);
    a.reset();
    const fresh = a.gain(0.5, 0, 10);
    expect(fresh).toBeLessThan(after);
  });
  it('scroll factor follows natural scrolling', () => {
    expect(scrollFactor(1, true)).toBeCloseTo(1.6);
    expect(scrollFactor(2, false)).toBeCloseTo(-3.2);
  });
});

describe('velocity', () => {
  it('uses the last 90 ms and needs a fresh last sample', () => {
    const s = [
      { t: 0, dx: 100, dy: 0 },
      { t: 50, dx: 10, dy: 0 },
      { t: 100, dx: 10, dy: 0 },
    ];
    const [vx] = velocity(s, 110);
    expect(vx).toBeCloseTo((20 / 50) * 1000);
    expect(velocity(s, 200)).toEqual([0, 0]);
    expect(velocity([{ t: 0, dx: 1, dy: 1 }], 1)).toEqual([0, 0]);
  });
});

describe('trackpad gestures', () => {
  let timers: FakeTimers;
  let sink: ReturnType<typeof recorder>;
  let settings: GestureSettings;
  let g: TrackpadGestures;
  beforeEach(() => {
    timers = new FakeTimers();
    sink = recorder();
    settings = { ...defaultSettings() };
    g = new TrackpadGestures(sink, () => settings, timers);
  });

  it('tap clicks after the deferred window with tap-and-drag on', () => {
    g.down(1, 100, 100, 0);
    g.lift(1, 100, 100, 100);
    expect(sink.names()).toEqual(['touch']);
    timers.advance(260);
    expect(sink.calls.at(-1)).toEqual(['click', 'left']);
  });

  it('tap clicks immediately with tap-and-drag off', () => {
    settings.tapAndDrag = false;
    g.down(1, 0, 0, 0);
    g.lift(1, 0, 0, 50);
    expect(sink.calls.at(-1)).toEqual(['click', 'left']);
  });

  it('slow tap does not click', () => {
    settings.tapAndDrag = false;
    g.down(1, 0, 0, 0);
    timers.advance(300);
    g.lift(1, 0, 0, 300);
    expect(sink.names()).not.toContain('click');
  });

  it('double tap gives two clicks', () => {
    g.down(1, 50, 50, 0);
    g.lift(1, 50, 50, 80);
    timers.advance(100);
    g.down(2, 60, 55, 180);
    g.lift(2, 60, 55, 250);
    expect(sink.calls.filter((c) => c[0] === 'click')).toEqual([
      ['click', 'left'],
      ['click', 'left'],
    ]);
  });

  it('tap then touch and move drags with the left button', () => {
    g.down(1, 50, 50, 0);
    g.lift(1, 50, 50, 80);
    timers.advance(100);
    g.down(2, 55, 50, 180);
    g.move(2, 80, 50, 200);
    g.lift(2, 80, 50, 260);
    const names = sink.names();
    expect(names).toContain('commitMods');
    expect(sink.calls).toContainEqual(['button', 'left', 'down']);
    expect(sink.calls.at(-1)).toEqual(['button', 'left', 'up']);
    expect(names.filter((n) => n === 'click')).toHaveLength(0);
  });

  it('second touch far away sends the pending click first', () => {
    g.down(1, 0, 0, 0);
    g.lift(1, 0, 0, 50);
    g.down(2, 200, 200, 100);
    expect(sink.calls).toContainEqual(['click', 'left']);
  });

  it('moving past 5 px points with the displacement from the start', () => {
    g.down(1, 0, 0, 0);
    g.move(1, 3, 0, 8);
    expect(sink.names()).toEqual(['touch']);
    g.move(1, 8, 0, 16);
    const mv = sink.calls.find((c) => c[0] === 'move');
    expect(mv?.[1] as number).toBeGreaterThan(8 * 0.8 * settings.pointerSpeed - 1e-6);
    g.move(1, 10, 0, 24);
    expect(sink.calls.filter((c) => c[0] === 'move')).toHaveLength(2);
  });

  it('two-finger tap right-clicks', () => {
    g.down(1, 0, 0, 0);
    g.down(2, 50, 0, 10);
    g.lift(1, 0, 0, 100);
    g.lift(2, 50, 0, 110);
    expect(sink.calls.at(-1)).toEqual(['click', 'right']);
  });

  it('two-finger move scrolls with phases and flings', () => {
    g.down(1, 0, 0, 0);
    g.down(2, 40, 0, 0);
    let t = 0;
    for (let i = 1; i <= 8; i++) {
      t += 10;
      g.move(1, 0, i * 10, t);
      g.move(2, 40, i * 10, t);
    }
    g.lift(1, 0, 80, t + 5);
    const scrolls = sink.calls.filter((c) => c[0] === 'scroll');
    expect(scrolls[0]).toEqual(['scroll', 1, 0, 0]);
    expect(scrolls.some((c) => c[1] === 2)).toBe(true);
    expect(scrolls.at(-1)).toEqual(['scroll', 4, 0, 0]);
    const fling = sink.calls.find((c) => c[0] === 'fling');
    expect(fling).toBeDefined();
    expect(fling?.[2] as number).toBeGreaterThan(0);
  });

  it('natural scroll off inverts the deltas', () => {
    settings.naturalScroll = false;
    g.down(1, 0, 0, 0);
    g.down(2, 40, 0, 0);
    g.move(1, 0, 20, 10);
    const changed = sink.calls.find((c) => c[0] === 'scroll' && c[1] === 2);
    expect(changed?.[3] as number).toBeLessThan(0);
  });

  it('pinch zooms in steps of 1.22', () => {
    g.down(1, 100, 100, 0);
    g.down(2, 200, 100, 0);
    g.move(1, 80, 100, 10);
    g.move(2, 220, 100, 10);
    expect(sink.calls).toContainEqual(['zoom', 1]);
  });

  it('three-finger swipe runs the configured action', () => {
    g.down(1, 0, 100, 0);
    g.down(2, 30, 100, 0);
    g.down(3, 60, 100, 0);
    for (const id of [1, 2, 3]) g.move(id, id * 30 - 30, 40, 20);
    expect(sink.calls).toContainEqual(['action', { kind: 'system', name: 'missionControl' }]);
  });

  it('four-finger left swipe uses the four-finger map', () => {
    for (let i = 1; i <= 4; i++) g.down(i, i * 20, 100, 0);
    for (let i = 1; i <= 4; i++) g.move(i, i * 20 - 60, 100, 20);
    expect(sink.calls).toContainEqual(['action', { kind: 'system', name: 'nextTab' }]);
  });

  it('three-finger tap uses the tap action', () => {
    for (let i = 1; i <= 3; i++) g.down(i, i * 20, 100, 0);
    for (let i = 1; i <= 3; i++) g.lift(i, i * 20, 100, 200);
    expect(sink.calls).toContainEqual(['action', { kind: 'mouse', button: 'middle' }]);
  });

  it('long press starts a drag; lifting releases it', () => {
    g.down(1, 0, 0, 0);
    timers.advance(450);
    expect(sink.calls).toContainEqual(['button', 'left', 'down']);
    g.move(1, 20, 0, 500);
    g.lift(1, 20, 0, 520);
    expect(sink.calls.at(-1)).toEqual(['button', 'left', 'up']);
  });

  it('long press as right click', () => {
    settings.longPress = 'rightClick';
    g.down(1, 0, 0, 0);
    timers.advance(450);
    expect(sink.calls).toContainEqual(['click', 'right']);
  });

  it('drag lock keeps the button down until the next tap', () => {
    settings.dragLock = true;
    g.down(1, 0, 0, 0);
    timers.advance(450);
    g.move(1, 30, 0, 500);
    g.lift(1, 30, 0, 520);
    expect(sink.calls.filter((c) => c[0] === 'button')).toEqual([['button', 'left', 'down']]);
    g.down(2, 30, 0, 700);
    g.lift(2, 30, 0, 750);
    expect(sink.calls.at(-1)).toEqual(['button', 'left', 'up']);
  });

  it('cancel releases a drag and cancels a scroll', () => {
    g.down(1, 0, 0, 0);
    timers.advance(450);
    g.cancel();
    expect(sink.calls.at(-1)).toEqual(['button', 'left', 'up']);
    g.down(1, 0, 0, 1000);
    g.down(2, 40, 0, 1000);
    g.move(1, 0, 20, 1010);
    g.cancel();
    expect(sink.calls.at(-1)).toEqual(['scroll', 8, 0, 0]);
  });
});

describe('scroll strip', () => {
  it('scrolls vertically and keeps scrolling past the end', () => {
    const timers = new FakeTimers();
    const calls: Call[] = [];
    const strip = new ScrollStrip(
      {
        touch: () => calls.push(['touch']),
        scroll: (p, dx, dy) => calls.push(['scroll', p, dx, dy]),
        fling: (vx, vy) => calls.push(['fling', vx, vy]),
      },
      () => ({ scrollSpeed: 1, naturalScroll: true, momentum: true }),
      timers,
    );
    strip.down(100);
    strip.move(110, 10);
    expect(calls[1]).toEqual(['scroll', 1, 0, 16]);
    strip.setOverflow(20);
    timers.advance(32);
    const held = calls.filter((c) => c[0] === 'scroll' && c[1] === 2);
    expect(held.length).toBeGreaterThanOrEqual(2);
    strip.up(200);
    expect(calls.at(-1)).toEqual(['scroll', 4, 0, 0]);
    expect(holdSpeed(20)).toBe(360 + 280);
    expect(holdSpeed(-1000)).toBe(-2400);
  });
});
