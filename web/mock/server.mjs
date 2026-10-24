// Fake Remoto Mac service for developing the web client without a Mac.
// Speaks protocol v1 over /ws, answers /api/info and /api/icon, and can serve
// a built client with the production CSP (`--web dist`).
//
//   node mock/server.mjs [--port 8741] [--web dist] [--manual] [--version 0.1.0]
//
// Type commands on stdin: p (pause), f (toggle Accessibility), v (toggle
// volume availability), b (bye reconnect), k (bye forget), s (toggle shell),
// l (toggle ISO layout), n (rotate code and PIN), a (approve) / r (reject)
// when --manual is set, h (help).
import { createServer } from 'node:http';
import { createHash, randomBytes, randomInt } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { join, extname, resolve, sep } from 'node:path';
import { tmpdir } from 'node:os';
import { deflateSync } from 'node:zlib';
import { createInterface } from 'node:readline';
import { WebSocketServer } from 'ws';

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? (args[i + 1] ?? def) : def;
};
const flag = (name) => args.includes(`--${name}`);

const PORT = Number(opt('port', process.env.MOCK_PORT ?? 8741));
const WEB = opt('web', null) ? resolve(opt('web', 'dist')) : null;
const VERSION = opt('version', '0.1.0');
const MANUAL = flag('manual');
const NAME = opt('name', 'Mock Mac');
const STATE_FILE = join(tmpdir(), 'remoto-mock-state.json');

const CSP =
  "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' ws: wss:; worker-src 'self'; manifest-src 'self'; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a);
const token = (n) => randomBytes(n).toString('base64url');
const sha = (s) => createHash('sha256').update(s).digest('hex');

// ---- persistent state (trusted devices, deck, settings) --------------------------
let state = { trusted: [], deck: null, settings: {} };
try {
  if (existsSync(STATE_FILE)) state = { ...state, ...JSON.parse(readFileSync(STATE_FILE, 'utf8')) };
} catch {
  log('state file unreadable, starting fresh');
}
const save = () => writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));

const sys = (id, label, icon, name) => ({ id, label, icon: { kind: 'symbol', name: icon }, action: { kind: 'system', name } });
const med = (id, label, icon, key) => ({ id, label, icon: { kind: 'symbol', name: icon }, action: { kind: 'media', key } });
const appTile = (label, id) => ({ id, label, icon: { kind: 'app', id }, action: { kind: 'app', id, op: 'toggle' } });
function defaultDeck() {
  return {
    version: 1,
    pages: [
      {
        id: 'essentials',
        name: 'Essentials',
        columns: 4,
        tiles: [
          sys('mission-control', 'Mission Control', 'layout-grid', 'missionControl'),
          sys('app-expose', 'App Windows', 'app-window', 'appExpose'),
          sys('desktop', 'Desktop', 'monitor', 'showDesktop'),
          sys('spotlight', 'Spotlight', 'search', 'spotlight'),
          sys('space-left', 'Space Left', 'arrow-left-to-line', 'spaceLeft'),
          sys('space-right', 'Space Right', 'arrow-right-to-line', 'spaceRight'),
          sys('screenshot', 'Screenshot', 'scan', 'screenshotArea'),
          sys('lock', 'Lock', 'lock', 'lockScreen'),
          med('previous', 'Previous', 'skip-back', 'previous'),
          med('play', 'Play / Pause', 'play-pause', 'playPause'),
          med('next', 'Next', 'skip-forward', 'next'),
          med('mute', 'Mute', 'volume-x', 'mute'),
          sys('copy', 'Copy', 'copy', 'copy'),
          sys('paste', 'Paste', 'clipboard', 'paste'),
          sys('undo', 'Undo', 'undo', 'undo'),
          sys('emoji', 'Emoji', 'smile', 'emojiPicker'),
        ],
      },
      {
        id: 'apps',
        name: 'Apps',
        columns: 4,
        tiles: [
          appTile('Finder', 'com.apple.finder'),
          appTile('Safari', 'com.apple.Safari'),
          appTile('Terminal', 'com.apple.Terminal'),
          appTile('Music', 'com.apple.Music'),
          appTile('Messages', 'com.apple.MobileSMS'),
          appTile('Notes', 'com.apple.Notes'),
          appTile('Calendar', 'com.apple.iCal'),
          appTile('Settings', 'com.apple.systempreferences'),
        ],
      },
    ],
  };
}
if (!state.deck) state.deck = defaultDeck();

// ---- layout ------------------------------------------------------------------------
const US = {
  0: 'aA', 1: 'sS', 2: 'dD', 3: 'fF', 4: 'hH', 5: 'gG', 6: 'zZ', 7: 'xX', 8: 'cC', 9: 'vV', 10: '§±', 11: 'bB',
  12: 'qQ', 13: 'wW', 14: 'eE', 15: 'rR', 16: 'yY', 17: 'tT', 18: '1!', 19: '2@', 20: '3#', 21: '4$', 22: '6^',
  23: '5%', 24: '=+', 25: '9(', 26: '7&', 27: '-_', 28: '8*', 29: '0)', 30: ']}', 31: 'oO', 32: 'uU', 33: '[{',
  34: 'iI', 35: 'pP', 37: 'lL', 38: 'jJ', 39: '\'"', 40: 'kK', 41: ';:', 42: '\\|', 43: ',<', 44: '/?', 45: 'nN',
  46: 'mM', 47: '.>', 50: '`~',
};
const OPT = { 0: 'å', 1: 'ß', 2: '∂', 3: 'ƒ', 8: 'ç', 14: '´', 32: '¨', 34: 'ˆ', 45: '˜', 50: '`' };
const DEAD_OPT = new Set([14, 32, 34, 45, 50]);
let iso = false;
function layout() {
  const codes = [];
  for (let c = 0x00; c <= 0x23; c++) codes.push(c);
  for (let c = 0x25; c <= 0x2f; c++) codes.push(c);
  codes.push(0x32, 0x5d, 0x5e, 0x5f);
  return {
    id: iso ? 'com.apple.keylayout.British' : 'com.apple.keylayout.US',
    name: iso ? 'British' : 'U.S.',
    iso,
    keys: codes.map((code) => {
      const pair = US[code] ?? '  ';
      const o = OPT[code] ?? '';
      return {
        code,
        base: pair[0].trim(),
        shift: pair[1].trim(),
        option: o,
        optionShift: o ? o.toUpperCase() : '',
        dead: DEAD_OPT.has(code) ? 4 : 0,
      };
    }),
  };
}

// ---- host state ----------------------------------------------------------------------
let paused = false;
let permission = true;
let shell = false;
let volume = { value: 0.42, muted: false };
let volumeAvailable = true;
let clipboard = 'Text from the mock Mac clipboard';
const apps = [
  ['com.apple.finder', 'Finder', true, false, false],
  ['com.apple.Safari', 'Safari', true, true, false],
  ['com.apple.Terminal', 'Terminal', true, false, true],
  ['com.apple.Music', 'Music', false, false, false],
  ['com.apple.MobileSMS', 'Messages', true, false, false],
  ['com.apple.Notes', 'Notes', false, false, false],
  ['com.apple.iCal', 'Calendar', false, false, false],
  ['com.apple.systempreferences', 'System Settings', false, false, false],
  ['com.apple.Preview', 'Preview', false, false, false],
  ['com.apple.TextEdit', 'TextEdit', false, false, false],
].map(([id, name, running, active, hidden]) => ({ id, name, running, active, hidden }));

// Pairing.
let code = token(18);
let pin = '';
const rotate = () => {
  code = token(18);
  do pin = String(randomInt(0, 1_000_000)).padStart(6, '0');
  while (/^(\d)\1{5}$/.test(pin) || pin === '123456' || pin === '654321');
  printPairing();
};
function printPairing() {
  log(`pair link: http://localhost:5173/#pair=${code}  (dev)   http://localhost:${PORT}/#pair=${code}  (--web)`);
  log(`PIN: ${pin}`);
}

const sessions = new Set();
const pendingApprovals = [];

// ---- HTTP ----------------------------------------------------------------------------------
const TYPES = {
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8', '.json': 'application/json', '.webmanifest': 'application/manifest+json',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.txt': 'text/plain; charset=utf-8',
  '.wasm': 'application/wasm',
};
const baseHeaders = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'Content-Security-Policy': CSP,
};

function crc32(buf) {
  let c = ~0;
  for (const b of buf) {
    c ^= b;
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c >>> 0;
}
function pngChunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
/** Solid rounded-ish square PNG with a color derived from the app id. */
function iconPng(id, size) {
  const h = createHash('md5').update(id).digest();
  const [r, g, b] = [h[0], h[1], h[2]].map((v) => 60 + (v % 160));
  const rows = [];
  const rad = size * 0.22;
  for (let y = 0; y < size; y++) {
    const row = Buffer.alloc(1 + size * 4);
    for (let x = 0; x < size; x++) {
      const dx = Math.max(rad - x, 0, x - (size - 1 - rad));
      const dy = Math.max(rad - y, 0, y - (size - 1 - rad));
      const inside = dx * dx + dy * dy <= rad * rad;
      row.set([r, g, b, inside ? 255 : 0], 1 + x * 4);
    }
    rows.push(row);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', deflateSync(Buffer.concat(rows))),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

const server = createServer((req, res) => {
  const url = new URL(req.url ?? '/', 'http://x');
  const send = (status, type, body, extra = {}) => {
    res.writeHead(status, { 'Content-Type': type, ...baseHeaders, ...extra });
    res.end(body);
  };
  if (url.pathname === '/api/info') {
    return send(200, 'application/json', JSON.stringify({ name: NAME, protocol: 1, secure: false, version: VERSION }), { 'Cache-Control': 'no-store' });
  }
  if (url.pathname === '/__mock/pairing') {
    return send(200, 'application/json', JSON.stringify({ code, pin }), { 'Cache-Control': 'no-store' });
  }
  if (url.pathname === '/api/icon') {
    const k = url.searchParams.get('k');
    if (![...sessions].some((s) => s.sessionKey === k)) return send(403, 'text/plain', 'Forbidden');
    const id = url.searchParams.get('id') ?? '';
    if (!id || !apps.some((a) => a.id === id)) return send(404, 'text/plain', 'Not Found');
    const raw = Number(url.searchParams.get('size') ?? 128);
    const size = raw <= 64 ? 64 : raw <= 128 ? 128 : raw <= 256 ? 256 : 512;
    return send(200, 'image/png', iconPng(id, size), { 'Cache-Control': 'private, max-age=86400' });
  }
  if (!WEB) return send(404, 'text/plain', 'Not Found (start with --web dist to serve the client)');
  const parts = url.pathname.split('/').filter(Boolean);
  if (parts.some((p) => p.startsWith('.') || p.includes('\\') || p.includes('\0'))) return send(404, 'text/plain', 'Not Found');
  let file = join(WEB, ...parts);
  if (!file.startsWith(WEB + sep) && file !== WEB) return send(404, 'text/plain', 'Not Found');
  if (existsSync(file) && statSync(file).isDirectory()) file = join(file, 'index.html');
  if (!existsSync(file)) {
    if (extname(url.pathname)) return send(404, 'text/plain', 'Not Found');
    file = join(WEB, 'index.html');
  }
  const cache = url.pathname.startsWith('/assets/') ? 'public, max-age=31536000, immutable' : 'no-cache';
  const extra = { 'Cache-Control': cache };
  if (url.pathname === '/sw.js') extra['Service-Worker-Allowed'] = '/';
  send(200, TYPES[extname(file)] ?? 'application/octet-stream', readFileSync(file), extra);
});

// ---- WebSocket sessions ----------------------------------------------------------------------
const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 * 1024 });
server.on('upgrade', (req, socket, head) => {
  if (new URL(req.url ?? '/', 'http://x').pathname !== '/ws') return socket.destroy();
  wss.handleUpgrade(req, socket, head, (ws) => session(ws, req.socket.remoteAddress ?? '?'));
});

const features = () => ({ voice: true, shell, secure: false, permission });
const broadcast = (msg) => {
  for (const s of sessions) s.send(msg);
};

function session(ws, ip) {
  const s = {
    ws,
    id: null,
    remembered: false,
    sessionKey: token(18),
    lastSeen: Date.now(),
    frames: { move: 0, scroll: 0, fling: 0, touch: 0, audio: 0, bad: 0 },
    voice: false,
    voiceText: '',
    send(msg) {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
    },
  };
  let handshake = true;
  const helloTimer = setTimeout(() => ws.close(), 10000);
  const watchdog = setInterval(() => {
    if (Date.now() - s.lastSeen > 8000) {
      log(`session ${s.id ?? '?'} silent > 8 s, closing`);
      ws.terminate();
    }
  }, 1000);
  const statsTimer = setInterval(() => {
    const f = s.frames;
    if (f.move + f.scroll + f.fling + f.touch + f.audio + f.bad) {
      log(`frames ${s.id}: move ${f.move} scroll ${f.scroll} fling ${f.fling} touch ${f.touch} audio ${f.audio} bad ${f.bad}`);
      s.frames = { move: 0, scroll: 0, fling: 0, touch: 0, audio: 0, bad: 0 };
    }
  }, 5000);

  ws.on('close', () => {
    clearTimeout(helloTimer);
    clearInterval(watchdog);
    clearInterval(statsTimer);
    sessions.delete(s);
    const i = pendingApprovals.findIndex((p) => p.s === s);
    if (i >= 0) pendingApprovals.splice(i, 1);
    log(`session closed ${s.id ?? ''}`);
  });

  const deny = (reason, retryAfter) => {
    s.send(retryAfter ? { t: 'denied', reason, retryAfter } : { t: 'denied', reason });
    ws.close();
  };

  const accept = (hello, method) => {
    clearTimeout(helloTimer);
    handshake = false;
    s.id = hello.device.id;
    let tk = null;
    if (method === 'token') s.remembered = true;
    else if (hello.remember === true) {
      tk = token(32);
      state.trusted = state.trusted.filter((d) => d.id !== s.id);
      state.trusted.push({ id: s.id, name: hello.device.name || 'Unnamed device', model: hello.device.model ?? '', tokenHash: sha(tk) });
      save();
      s.remembered = true;
    }
    if (method === 'pair' || method === 'pin') rotate();
    sessions.add(s);
    const welcome = {
      t: 'welcome',
      v: 1,
      host: { name: NAME, version: VERSION, os: 'macOS' },
      sessionKey: s.sessionKey,
      token: tk,
      features: features(),
      deck: state.deck,
      layout: layout(),
    };
    if (volumeAvailable) welcome.volume = volume;
    welcome.paused = paused;
    if (s.remembered && state.settings[s.id]) welcome.settings = state.settings[s.id];
    s.send(welcome);
    log(`welcome ${hello.device.name || hello.device.model} (${method}${s.remembered ? ', remembered' : ''})`);
  };

  ws.on('message', (data, isBinary) => {
    s.lastSeen = Date.now();
    if (isBinary) {
      if (handshake) return;
      const buf = Buffer.from(data);
      const t = buf[0];
      const ok =
        (t === 1 && buf.length === 9) || (t === 2 && buf.length === 10) || (t === 3 && buf.length === 9) || (t === 4 && buf.length === 1) || (t === 0x10 && buf.length >= 3 && buf.length % 2 === 1);
      if (!ok) return void s.frames.bad++;
      const name = { 1: 'move', 2: 'scroll', 3: 'fling', 4: 'touch', 16: 'audio' }[t];
      s.frames[name]++;
      if (t === 0x10 && s.voice) voiceFeed(s);
      return;
    }
    let msg;
    try {
      msg = JSON.parse(String(data));
    } catch {
      if (handshake) {
        s.send({ t: 'bye', reason: 'Expected a hello message.', reconnect: false });
        return ws.close();
      }
      return log('invalid JSON ignored');
    }
    if (handshake) return handleHello(msg);
    handle(msg);
  });

  function handleHello(msg) {
    if (msg?.t !== 'hello') {
      s.send({ t: 'bye', reason: 'Expected a hello message.', reconnect: false });
      return ws.close();
    }
    if (msg.v !== 1) return deny('incompatible');
    const id = msg.device?.id;
    if (typeof id !== 'string' || !/^[\x21-\x7e]{1,128}$/.test(id)) return deny('incompatible');
    const auth = msg.auth ?? {};
    switch (auth.method) {
      case 'token': {
        const entry = state.trusted.find((d) => d.id === id && d.tokenHash === sha(String(auth.token ?? '')));
        return entry ? accept(msg, 'token') : deny('unknown');
      }
      case 'pair':
        if (auth.code === code) return accept(msg, 'pair');
        return deny('expiredCode');
      case 'pin': {
        const digits = String(auth.pin ?? '').replace(/\D/g, '');
        if (digits === pin) return accept(msg, 'pin');
        return deny('wrongPin');
      }
      case 'approve': {
        if (pendingApprovals.length >= 2) return deny('busy');
        s.send({ t: 'pending' });
        const entry = { s, msg };
        pendingApprovals.push(entry);
        log(`approval requested by ${msg.device.name || msg.device.model}${MANUAL ? ' (type a or r)' : ' (auto-approving in 1.5 s)'}`);
        if (!MANUAL) setTimeout(() => resolveApproval(true), 1500);
        return;
      }
      default:
        return deny('incompatible');
    }
  }

  s.resolveApproval = (ok) => {
    const i = pendingApprovals.findIndex((p) => p.s === s);
    if (i < 0) return;
    const [{ msg }] = pendingApprovals.splice(i, 1);
    if (ok) accept(msg, 'approve');
    else deny('rejected');
  };
  // Handle ping while waiting for approval.
  ws.on('message', (data, isBinary) => {
    if (isBinary || !handshake) return;
    try {
      const m = JSON.parse(String(data));
      if (m?.t === 'ping' && pendingApprovals.some((p) => p.s === s)) s.send({ t: 'pong', id: m.id });
    } catch {
      // ignore
    }
  });

  function handle(m) {
    switch (m.t) {
      case 'ping':
        return s.send({ t: 'pong', id: m.id });
      case 'key':
      case 'tap':
      case 'button':
      case 'release':
        if (!permission) return s.send({ t: 'notice', level: 'warning', code: 'permission', message: 'Remoto needs Accessibility permission on the Mac.' });
        return log(m.t, JSON.stringify(m));
      case 'media':
        if (m.key === 'volumeUp' || m.key === 'volumeDown') {
          volume = { ...volume, value: Math.min(1, Math.max(0, volume.value + (m.key === 'volumeUp' ? 0.0625 : -0.0625))) };
          if (volumeAvailable) broadcast({ t: 'volume', ...volume });
        } else if (m.key === 'mute') {
          volume = { ...volume, muted: !volume.muted };
          if (volumeAvailable) broadcast({ t: 'volume', ...volume });
        }
        return log('media', m.key, m.op ?? 'click');
      case 'volume':
        if (typeof m.value === 'number' && Number.isFinite(m.value)) volume.value = Math.min(1, Math.max(0, m.value));
        if (typeof m.muted === 'boolean') volume.muted = m.muted;
        if (volumeAvailable) broadcast({ t: 'volume', ...volume });
        return;
      case 'text':
        if (paused) return s.send({ t: 'notice', level: 'warning', code: 'paused', message: 'Control is paused on the Mac.' });
        if (Buffer.byteLength(String(m.text)) > 65536) return s.send({ t: 'notice', level: 'warning', code: 'tooLong', message: 'That text is too long.' });
        return log('text', JSON.stringify(m.text), m.mode ?? 'unicode');
      case 'edit':
        return log('edit', `-${m.delete ?? 0}`, JSON.stringify(m.insert ?? ''));
      case 'action':
        return runAction(m);
      case 'apps':
        return s.send({ t: 'apps', apps: [...apps].sort((a, b) => a.name.localeCompare(b.name)) });
      case 'appAction': {
        const a = apps.find((x) => x.id === m.id);
        if (!a) return s.send({ t: 'notice', level: 'error', message: 'App not found.' });
        const op = m.op ?? 'toggle';
        if (op === 'quit') Object.assign(a, { running: false, active: false, hidden: false });
        else if (op === 'hide') Object.assign(a, { hidden: true, active: false });
        else if (op === 'toggle' && a.active && !a.hidden) Object.assign(a, { hidden: true, active: false });
        else {
          for (const x of apps) x.active = false;
          Object.assign(a, { running: true, active: true, hidden: false });
        }
        return setTimeout(() => broadcast({ t: 'appsChanged' }), 400);
      }
      case 'deckSave': {
        const err = validateDeck(m.deck);
        if (err) return s.send({ t: 'notice', level: 'error', code: 'deck', message: err });
        state.deck = m.deck;
        save();
        return broadcast({ t: 'deck', deck: state.deck });
      }
      case 'voiceStart':
        s.voice = true;
        s.voiceText = '';
        s.voiceFrames = 0;
        log('voiceStart', m.locale ?? '');
        return s.send({ t: 'voice', state: 'listening', final: false });
      case 'voiceStop':
        if (!s.voice) return;
        s.voice = false;
        return s.send(m.cancel ? { t: 'voice', state: 'stopped', final: true } : { t: 'voice', state: 'stopped', text: s.voiceText, final: true });
      case 'clipboardSet':
        clipboard = String(m.text ?? '');
        return log('clipboard set', JSON.stringify(clipboard.slice(0, 40)));
      case 'clipboardGet':
        return s.send({ t: 'clipboard', text: clipboard || null });
      case 'settingsSave': {
        if (!s.remembered) return;
        if (typeof m.settings !== 'object' || m.settings === null || Array.isArray(m.settings)) {
          return s.send({ t: 'notice', level: 'error', code: 'settings', message: 'Settings must be an object.' });
        }
        const prev = state.settings[s.id];
        if (prev && prev.updatedAt >= m.updatedAt) return;
        state.settings[s.id] = { settings: m.settings, updatedAt: m.updatedAt };
        save();
        return log('settings saved', m.updatedAt);
      }
      case 'settingsList': {
        const devices = state.trusted
          .filter((d) => d.id !== s.id && state.settings[d.id])
          .map((d) => ({ id: d.id, name: d.name, model: d.model, updatedAt: state.settings[d.id].updatedAt }));
        if (!devices.length) devices.push({ id: 'mock-ipad', name: 'Mock iPad', model: 'iPad', updatedAt: Date.now() - 5 * 60000 });
        devices.sort((a, b) => b.updatedAt - a.updatedAt);
        return s.send({ t: 'settingsList', devices });
      }
      case 'settingsCopy': {
        if (!s.remembered) return s.send({ t: 'notice', level: 'warning', code: 'settings', message: 'Turn on “Remember this device” to copy settings.' });
        const src = state.settings[m.from] ?? (m.from === 'mock-ipad' ? { settings: { version: 1, settings: { pointerSpeed: 2, theme: 'dark' }, keyboards: [] }, updatedAt: Date.now() } : null);
        if (!src) return s.send({ t: 'notice', level: 'warning', code: 'settings', message: 'Those settings are no longer on the Mac.' });
        return s.send({ t: 'settings', ...src });
      }
      default:
        return log('ignored', m.t);
    }
  }

  function runAction(m) {
    const reply = (ok, message) => {
      if (m.id === undefined && ok) return;
      const r = { t: 'actionResult' };
      if (m.id !== undefined) r.id = m.id;
      r.ok = ok;
      if (message) r.message = message;
      s.send(r);
    };
    const a = m.action ?? {};
    log('action', JSON.stringify(a));
    if (paused) return reply(false, 'Stopped because control is paused.');
    if (a.kind === 'shell' && !shell) return reply(false, 'Shell commands are turned off in the Mac settings.');
    if (a.kind === 'url' && /^(javascript|data):/i.test(String(a.url))) return reply(false, 'That kind of link is not allowed.');
    if (a.kind === 'app' && !apps.some((x) => x.id === a.id)) return setTimeout(() => reply(false, 'App not found.'), 300);
    const ms = a.kind === 'delay' ? Math.min(10000, a.ms) : a.kind === 'sequence' ? 600 : 120;
    setTimeout(() => reply(true), ms);
  }

  function voiceFeed() {
    s.voiceFrames = (s.voiceFrames ?? 0) + 1;
    const words = ['this', 'is', 'mock', 'dictation', 'from', 'the', 'fake', 'Mac'];
    if (s.voiceFrames % 8 === 0) {
      const n = Math.min(words.length, s.voiceFrames / 8);
      s.voiceText = words.slice(0, n).join(' ');
      const final = n === words.length;
      s.send({ t: 'voice', state: 'listening', text: s.voiceText, final });
      if (final) {
        s.voiceFrames = 0;
        s.voiceText = '';
      }
    }
  }
}

function resolveApproval(ok) {
  const p = pendingApprovals[0];
  if (p) p.s.resolveApproval(ok);
}

function validateDeck(d) {
  if (!d || d.version !== 1 || !Array.isArray(d.pages)) return 'Unsupported deck version.';
  if (d.pages.length < 1 || d.pages.length > 24) return 'The deck has too many pages or buttons.';
  for (const p of d.pages) {
    if (!Number.isInteger(p.columns) || p.columns < 1 || p.columns > 8) return 'Columns must be between 1 and 8.';
    if (!Array.isArray(p.tiles) || p.tiles.length > 64) return 'The deck has too many pages or buttons.';
    for (const t of p.tiles) {
      if (typeof t.label !== 'string' || [...t.label].length > 80) return 'Label too long.';
      if (t.color !== undefined && !(/^#[0-9a-f]+$/i.test(t.color) && [4, 5, 7, 9].includes(t.color.length))) return 'Invalid color.';
    }
  }
  return null;
}

// ---- stdin commands -------------------------------------------------------------------------------
const rl = process.stdin.isTTY ? createInterface({ input: process.stdin }) : null;
rl?.on('line', (line) => {
  switch (line.trim()) {
    case 'p':
      paused = !paused;
      broadcast({ t: 'paused', paused });
      return log('paused', paused);
    case 'f':
      permission = !permission;
      for (const s of sessions) s.send({ t: 'features', features: features() });
      return log('permission', permission);
    case 's':
      shell = !shell;
      for (const s of sessions) s.send({ t: 'features', features: features() });
      return log('shell', shell);
    case 'v':
      volumeAvailable = !volumeAvailable;
      broadcast(volumeAvailable ? { t: 'volume', ...volume } : { t: 'volumeUnavailable' });
      return log('volume available', volumeAvailable);
    case 'l':
      iso = !iso;
      broadcast({ t: 'layout', layout: layout() });
      return log('iso', iso);
    case 'b':
      for (const s of sessions) {
        s.send({ t: 'bye', reason: 'The Mac stopped sharing.', reconnect: true });
        s.ws.close();
      }
      return;
    case 'k':
      for (const s of sessions) {
        s.send({ t: 'bye', reason: 'This device was removed on the Mac. Pair it again.', reconnect: false });
        s.ws.close();
      }
      state.trusted = [];
      save();
      return;
    case 'n':
      return rotate();
    case 'a':
      return resolveApproval(true);
    case 'r':
      return resolveApproval(false);
    default:
      return log('commands: p pause, f permission, s shell, v volume, l layout, b bye, k forget, n new code, a/r approve/reject');
  }
});

server.listen(PORT, '0.0.0.0', () => {
  log(`mock Mac "${NAME}" v${VERSION} on http://localhost:${PORT}${WEB ? ` serving ${WEB}` : ''}`);
  rotate();
});
