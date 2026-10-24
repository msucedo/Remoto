import { describe, expect, it } from 'vitest';
import { decode, encode, out } from '../src/protocol/codec';
import { audioFrame, decodeFrame, flingFrame, moveFrame, scrollFrame, touchFrame } from '../src/protocol/binary';
import { ScrollPhase } from '../src/protocol/types';

const device = { id: 'dev-1', name: 'Phone', model: 'iPhone' };

describe('client message encoding', () => {
  const cases: [string, ReturnType<typeof out.ping>, string][] = [
    ['hello token', out.hello(device, { method: 'token', token: 'T' }, true),
      '{"t":"hello","v":1,"device":{"id":"dev-1","name":"Phone","model":"iPhone"},"auth":{"method":"token","token":"T"},"remember":true}'],
    ['hello pair', out.hello(device, { method: 'pair', code: 'abc' }, false),
      '{"t":"hello","v":1,"device":{"id":"dev-1","name":"Phone","model":"iPhone"},"auth":{"method":"pair","code":"abc"},"remember":false}'],
    ['hello pin', out.hello(device, { method: 'pin', pin: '482913' }, true),
      '{"t":"hello","v":1,"device":{"id":"dev-1","name":"Phone","model":"iPhone"},"auth":{"method":"pin","pin":"482913"},"remember":true}'],
    ['hello approve', out.hello(device, { method: 'approve' }, true),
      '{"t":"hello","v":1,"device":{"id":"dev-1","name":"Phone","model":"iPhone"},"auth":{"method":"approve"},"remember":true}'],
    ['ping', out.ping(7), '{"t":"ping","id":7}'],
    ['key down', out.key(0, true, 2, true), '{"t":"key","code":0,"down":true,"mods":2,"repeat":true}'],
    ['key up', out.key(0, false), '{"t":"key","code":0,"down":false}'],
    ['tap', out.tap(36), '{"t":"tap","code":36}'],
    ['tap mods', out.tap(24, 1), '{"t":"tap","code":24,"mods":1}'],
    ['button', out.button('left', 'down'), '{"t":"button","button":"left","op":"down"}'],
    ['media click', out.media('playPause'), '{"t":"media","key":"playPause"}'],
    ['media down', out.media('rewind', 'down'), '{"t":"media","key":"rewind","op":"down"}'],
    ['volume value', out.volume({ value: 1.5, muted: false }), '{"t":"volume","value":1,"muted":false}'],
    ['volume nan', out.volume({ value: Number.NaN }), '{"t":"volume"}'],
    ['volume mute', out.volume({ muted: true }), '{"t":"volume","muted":true}'],
    ['text', out.text('hola'), '{"t":"text","text":"hola"}'],
    ['text paste', out.text('x', 'paste'), '{"t":"text","text":"x","mode":"paste"}'],
    ['edit', out.edit(2, 'é'), '{"t":"edit","delete":2,"insert":"é"}'],
    ['release', out.release(), '{"t":"release"}'],
    ['action', out.action({ kind: 'system', name: 'copy' }, 3), '{"t":"action","action":{"kind":"system","name":"copy"},"id":3}'],
    ['action no id', out.action({ kind: 'media', key: 'mute' }), '{"t":"action","action":{"kind":"media","key":"mute"}}'],
    ['apps', out.apps(), '{"t":"apps"}'],
    ['appAction', out.appAction('com.apple.Safari', 'quit'), '{"t":"appAction","id":"com.apple.Safari","op":"quit"}'],
    ['deckSave', out.deckSave({ version: 1, pages: [] }), '{"t":"deckSave","deck":{"version":1,"pages":[]}}'],
    ['voiceStart', out.voiceStart('es-MX'), '{"t":"voiceStart","locale":"es-MX"}'],
    ['voiceStop', out.voiceStop(true), '{"t":"voiceStop","cancel":true}'],
    ['clipboardSet', out.clipboardSet('a'), '{"t":"clipboardSet","text":"a"}'],
    ['clipboardGet', out.clipboardGet(), '{"t":"clipboardGet"}'],
    ['settingsSave', out.settingsSave({ a: 1 }, 5), '{"t":"settingsSave","settings":{"a":1},"updatedAt":5}'],
    ['settingsList', out.settingsList(), '{"t":"settingsList"}'],
    ['settingsCopy', out.settingsCopy('x'), '{"t":"settingsCopy","from":"x"}'],
  ];
  for (const [name, msg, json] of cases) {
    it(name, () => expect(encode(msg)).toBe(json));
  }
});

describe('server message decoding', () => {
  const deck = { version: 1, pages: [] };
  it('welcome with every optional field', () => {
    const m = decode(
      JSON.stringify({
        t: 'welcome',
        v: 1,
        host: { name: 'Mac', version: '0.1.0', os: 'macOS' },
        sessionKey: 'k',
        token: 'tok',
        features: { voice: true, shell: false, secure: true, permission: false },
        deck,
        layout: { id: 'us', name: 'U.S.', iso: true, keys: [{ code: 0, base: 'a', shift: 'A', option: 'å', optionShift: 'Å', dead: 0 }] },
        volume: { value: 0.5, muted: true },
        paused: true,
        settings: { settings: { x: 1 }, updatedAt: 9 },
      }),
    );
    expect(m).toMatchObject({
      t: 'welcome',
      token: 'tok',
      sessionKey: 'k',
      paused: true,
      features: { voice: true, shell: false, secure: true, permission: false },
      volume: { value: 0.5, muted: true },
      settings: { settings: { x: 1 }, updatedAt: 9 },
    });
    expect(m && m.t === 'welcome' && m.layout?.iso).toBe(true);
  });
  it('welcome with null token and no optional fields', () => {
    const m = decode('{"t":"welcome","v":1,"host":{"name":"M","version":"1","os":"macOS"},"sessionKey":"k","token":null,"features":{"voice":false,"shell":false,"secure":false,"permission":true},"deck":{"version":1,"pages":[]},"paused":false}');
    expect(m).toMatchObject({ t: 'welcome', token: null });
    expect(m && 'layout' in m).toBe(false);
    expect(m && 'volume' in m).toBe(false);
  });
  it('welcome without deck is rejected', () => {
    expect(decode('{"t":"welcome","host":{},"features":{}}')).toBeNull();
  });
  it('simple messages', () => {
    expect(decode('{"t":"pending"}')).toEqual({ t: 'pending' });
    expect(decode('{"t":"denied","reason":"blocked","retryAfter":30}')).toEqual({ t: 'denied', reason: 'blocked', retryAfter: 30 });
    expect(decode('{"t":"denied","reason":"wrongPin"}')).toEqual({ t: 'denied', reason: 'wrongPin' });
    expect(decode('{"t":"pong","id":"x"}')).toEqual({ t: 'pong', id: 'x' });
    expect(decode('{"t":"appsChanged"}')).toEqual({ t: 'appsChanged' });
    expect(decode('{"t":"volumeUnavailable"}')).toEqual({ t: 'volumeUnavailable' });
    expect(decode('{"t":"paused","paused":true}')).toEqual({ t: 'paused', paused: true });
    expect(decode('{"t":"volume","value":0.3,"muted":false}')).toEqual({ t: 'volume', value: 0.3, muted: false });
    expect(decode('{"t":"clipboard","text":null}')).toEqual({ t: 'clipboard', text: null });
    expect(decode('{"t":"bye","reason":"Bye","reconnect":true}')).toEqual({ t: 'bye', reason: 'Bye', reconnect: true });
    expect(decode('{"t":"deck","deck":{"version":1,"pages":[]}}')).toEqual({ t: 'deck', deck });
    expect(decode('{"t":"settings","settings":{"a":1},"updatedAt":3}')).toEqual({ t: 'settings', settings: { a: 1 }, updatedAt: 3 });
  });
  it('apps, features, layout', () => {
    expect(decode('{"t":"apps","apps":[{"id":"a","name":"A","running":true,"active":false,"hidden":false},{"bad":1}]}')).toEqual({
      t: 'apps',
      apps: [{ id: 'a', name: 'A', running: true, active: false, hidden: false }],
    });
    expect(decode('{"t":"features","features":{"voice":true,"shell":true,"secure":false,"permission":true}}')).toEqual({
      t: 'features',
      features: { voice: true, shell: true, secure: false, permission: true },
    });
    const l = decode('{"t":"layout","layout":{"id":"x","name":"X","iso":false,"keys":[{"code":12,"base":"q","shift":"Q","option":"œ","optionShift":"Œ","dead":0}]}}');
    expect(l && l.t === 'layout' && l.layout.keys[0]?.option).toBe('œ');
  });
  it('notice defaults the level and omits a missing code', () => {
    expect(decode('{"t":"notice","message":"hi"}')).toEqual({ t: 'notice', level: 'info', message: 'hi' });
    expect(decode('{"t":"notice","level":"error","code":"deck","message":"no"}')).toEqual({ t: 'notice', level: 'error', code: 'deck', message: 'no' });
  });
  it('actionResult keeps id and message only when present', () => {
    expect(decode('{"t":"actionResult","id":4,"ok":true}')).toEqual({ t: 'actionResult', id: 4, ok: true });
    expect(decode('{"t":"actionResult","ok":false,"message":"busy"}')).toEqual({ t: 'actionResult', ok: false, message: 'busy' });
  });
  it('voice', () => {
    expect(decode('{"t":"voice","state":"listening","text":"ho","final":false}')).toEqual({ t: 'voice', state: 'listening', text: 'ho', final: false });
    expect(decode('{"t":"voice","state":"weird","final":false}')).toBeNull();
  });
  it('settingsList', () => {
    expect(decode('{"t":"settingsList","devices":[{"id":"a","name":"iPad","model":"iPad","updatedAt":5}]}')).toEqual({
      t: 'settingsList',
      devices: [{ id: 'a', name: 'iPad', model: 'iPad', updatedAt: 5 }],
    });
  });
  it('unknown and invalid input', () => {
    expect(decode('not json')).toBeNull();
    expect(decode('{"t":"mystery"}')).toBeNull();
    expect(decode('[1,2]')).toBeNull();
  });
});

describe('binary frames', () => {
  it('Move is 9 bytes, little-endian f32', () => {
    const buf = moveFrame(1.5, -2);
    expect(buf.byteLength).toBe(9);
    const v = new DataView(buf);
    expect(v.getUint8(0)).toBe(0x01);
    expect(v.getFloat32(1, true)).toBe(1.5);
    expect(v.getFloat32(5, true)).toBe(-2);
    expect(Array.from(new Uint8Array(buf))).toEqual([1, 0, 0, 0xc0, 0x3f, 0, 0, 0, 0xc0]);
  });
  it('Scroll is 10 bytes with phase', () => {
    const buf = scrollFrame(ScrollPhase.Changed, 3, 4);
    expect(buf.byteLength).toBe(10);
    expect(decodeFrame(buf)).toEqual({ type: 'scroll', phase: 2, dx: 3, dy: 4 });
  });
  it('Fling and Touch', () => {
    expect(decodeFrame(flingFrame(100, -50))).toEqual({ type: 'fling', vx: 100, vy: -50 });
    expect(touchFrame().byteLength).toBe(1);
    expect(decodeFrame(touchFrame())).toEqual({ type: 'touch' });
  });
  it('Audio is 0x10 + Int16 LE, odd length', () => {
    const buf = audioFrame(new Int16Array([1, -1, 32767, -32768]));
    expect(buf.byteLength).toBe(9);
    expect(Array.from(new Uint8Array(buf))).toEqual([0x10, 1, 0, 0xff, 0xff, 0xff, 0x7f, 0x00, 0x80]);
    const d = decodeFrame(buf);
    expect(d?.type === 'audio' && Array.from(d.pcm)).toEqual([1, -1, 32767, -32768]);
    expect(audioFrame(new Int16Array(1600)).byteLength).toBe(3201);
  });
  it('rejects wrong lengths and non-finite values', () => {
    expect(decodeFrame(new Uint8Array([1, 0, 0, 0, 0, 0, 0, 0]).buffer)).toBeNull();
    expect(decodeFrame(moveFrame(Number.NaN, 0))).toBeNull();
    expect(decodeFrame(new Uint8Array([0x10, 0]).buffer)).toBeNull();
    expect(decodeFrame(new Uint8Array([0x99]).buffer)).toBeNull();
  });
});
