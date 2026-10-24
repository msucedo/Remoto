import { describe, expect, it } from 'vitest';
import {
  applyBlob,
  blobHash,
  defaultSettings,
  fnv1a,
  makeBlob,
  nextUpdatedAt,
  resetSettings,
  validateSettings,
} from '../src/store/settings';
import { boardFromTemplate, emptyBoard, placementError, validateKeyboards } from '../src/store/keyboards';
import { detectModel } from '../src/device';
import { resolveKeyboardMode } from '../src/views/keyboard-mode';

describe('settings validation', () => {
  it('defaults match the spec', () => {
    const d = defaultSettings();
    expect(d).toMatchObject({ pointerSpeed: 1.2, pointerAcceleration: 0.6, longPress: 'drag', scrollStrip: 'short', keyboard: 'auto', textMode: 'unicode', tab: 'trackpad' });
    expect(d.fourFinger.tap).toBeNull();
    expect(d.threeFinger.tap).toEqual({ kind: 'mouse', button: 'middle' });
  });
  it('clamps numbers, checks enums and types', () => {
    const s = validateSettings({ pointerSpeed: 99, scrollSpeed: -1, theme: 'neon', tapToClick: 'yes', tab: 'apps', deviceName: 'x'.repeat(50), extra: 1 });
    expect(s.pointerSpeed).toBe(4);
    expect(s.scrollSpeed).toBe(0.2);
    expect(s.theme).toBe('system');
    expect(s.tapToClick).toBe(true);
    expect(s.tab).toBe('apps');
    expect(s.deviceName).toHaveLength(40);
    expect('extra' in s).toBe(false);
  });
  it('invalid gesture actions fall back to the defaults', () => {
    const s = validateSettings({ threeFinger: { up: { kind: 'system', name: 'bogus' }, down: null } });
    expect(s.threeFinger.up).toEqual({ kind: 'system', name: 'missionControl' });
    expect(s.threeFinger.down).toBeNull();
  });
  it('reset keeps name, tab and deck page', () => {
    const cur = { ...defaultSettings(), deviceName: 'Mine', tab: 'deck' as const, deckPage: 'p1', pointerSpeed: 3 };
    const r = resetSettings(cur);
    expect(r).toMatchObject({ deviceName: 'Mine', tab: 'deck', deckPage: 'p1', pointerSpeed: 1.2 });
  });
});

describe('settings sync blob', () => {
  it('excludes device-local keys', () => {
    const blob = makeBlob({ ...defaultSettings(), deviceName: 'X' }, []);
    for (const k of ['version', 'deviceName', 'rememberDevice', 'tab', 'deckPage']) expect(k in blob.settings).toBe(false);
    expect(blob.version).toBe(1);
  });
  it('hash ignores board and key ids', () => {
    const a = boardFromTemplate('editing', 'E');
    const b = { ...a, id: 'other', keys: a.keys.map((k, i) => ({ ...k, id: `k${i}` })) };
    expect(blobHash(makeBlob(defaultSettings(), [a]))).toBe(blobHash(makeBlob(defaultSettings(), [b])));
    expect(blobHash(makeBlob({ ...defaultSettings(), pointerSpeed: 2 }, [a]))).not.toBe(blobHash(makeBlob(defaultSettings(), [a])));
  });
  it('FNV-1a known vectors', () => {
    expect(fnv1a('')).toBe(0x811c9dc5);
    expect(fnv1a('a')).toBe(0xe40c292c);
    expect(fnv1a('foobar')).toBe(0xbf9cf968);
  });
  it('applying keeps local keys and drops invalid gestures', () => {
    const cur = { ...defaultSettings(), deviceName: 'Mine', tab: 'media' as const };
    const r = applyBlob({ version: 1, settings: { pointerSpeed: 2, deviceName: 'Theirs', tab: 'deck', fourFinger: { up: { kind: 'nope' } } }, keyboards: [emptyBoard('K')] }, cur);
    expect(r?.settings).toMatchObject({ pointerSpeed: 2, deviceName: 'Mine', tab: 'media' });
    expect(r?.settings.fourFinger.up).toEqual({ kind: 'system', name: 'launchpad' });
    expect(r?.keyboards).toHaveLength(1);
    expect(applyBlob('nope', cur)).toBeNull();
  });
  it('updatedAt is strictly increasing', () => {
    expect(nextUpdatedAt(100, 50)).toBe(101);
    expect(nextUpdatedAt(100, 500)).toBe(500);
  });
});

describe('custom keyboards', () => {
  it('templates are valid and placement checks overlap and bounds', () => {
    const b = boardFromTemplate('gamepad', 'G');
    expect(validateKeyboards({ boards: [b] }).boards).toHaveLength(1);
    const k = b.keys[0];
    if (!k) throw new Error('no key');
    expect(placementError(b, { ...k, id: 'new' })).toBe('overlap');
    expect(placementError(b, { ...k, id: 'new', x: 6 })).toBe('outside');
  });
  it('drops invalid boards and overlapping keys', () => {
    const bad = { ...emptyBoard('x'), cols: 20 };
    const overlapping = { ...emptyBoard('y'), keys: [
      { id: 'a', x: 0, y: 0, w: 2, h: 1, action: { kind: 'key', code: 0, mods: 0 } },
      { id: 'b', x: 1, y: 0, w: 1, h: 1, action: { kind: 'key', code: 1, mods: 0 } },
    ] };
    expect(validateKeyboards({ boards: [bad, overlapping] }).boards).toHaveLength(0);
  });
});

describe('device and keyboard mode', () => {
  it('detects models from the user agent', () => {
    expect(detectModel('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)', 5)).toBe('iPhone');
    expect(detectModel('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', 5)).toBe('iPad');
    expect(detectModel('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', 0)).toBe('Mac');
    expect(detectModel('Mozilla/5.0 (Linux; Android 14; Pixel 8) Mobile', 5)).toBe('Android phone');
    expect(detectModel('Mozilla/5.0 (Linux; Android 14; SM-X710)', 5)).toBe('Android tablet');
    expect(detectModel('Mozilla/5.0 (Windows NT 10.0)', 0)).toBe('Windows PC');
    expect(detectModel('curl', 0)).toBe('Browser');
  });
  it('auto keyboard mode', () => {
    expect(resolveKeyboardMode('auto', false, 390)).toBe('phone');
    expect(resolveKeyboardMode('auto', false, 600)).toBe('mac');
    expect(resolveKeyboardMode('auto', true, 390)).toBe('mac');
    expect(resolveKeyboardMode('custom', false, 390)).toBe('custom');
  });
});
