// End-to-end smoke test in headless Chrome over CDP: pairs with the mock (or
// a real Mac with --pin), walks every tab, takes screenshots and fails on any
// console error or uncaught exception.
//
//   node scripts/cdp-check.mjs [--url http://localhost:5173] [--out DIR]
//                              [--pin 123456 | --approve] [--dark] [--es] [--landscape]
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from 'ws';

const args = process.argv.slice(2);
const opt = (n, d) => {
  const i = args.indexOf(`--${n}`);
  return i >= 0 ? args[i + 1] : d;
};
const flag = (n) => args.includes(`--${n}`);
const BASE = opt('url', 'http://localhost:5173').replace(/\/$/, '');
const OUT = opt('out', join(tmpdir(), 'remoto-cdp'));
const PIN = opt('pin', null);
const PORT = Number(opt('port', 9339));
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const [W, H] = flag('landscape') ? [844, 390] : [390, 844];
mkdirSync(OUT, { recursive: true });

const profile = mkdtempSync(join(tmpdir(), 'remoto-chrome-'));
const chrome = spawn(CHROME, [
  '--headless=new',
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${profile}`,
  '--no-first-run',
  '--no-default-browser-check',
  `--window-size=${W},${H}`,
  `--lang=${flag('es') ? 'es-MX' : 'en-US'}`,
  'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const problems = [];
let ws;
let seq = 0;
const waiting = new Map();
const handlers = [];

function send(method, params = {}, sessionId) {
  const id = ++seq;
  ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  return new Promise((resolve, reject) => waiting.set(id, { resolve, reject }));
}

async function main() {
  let version;
  for (let i = 0; i < 50 && !version; i++) {
    try {
      version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
    } catch {
      await sleep(100);
    }
  }
  if (!version) throw new Error('Chrome did not start');
  ws = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((r) => ws.once('open', r));
  ws.on('message', (raw) => {
    const m = JSON.parse(String(raw));
    if (m.id && waiting.has(m.id)) {
      const w = waiting.get(m.id);
      waiting.delete(m.id);
      if (m.error) w.reject(new Error(`${m.error.message}`));
      else w.resolve(m.result);
    } else if (m.method) {
      for (const h of handlers) h(m);
    }
  });

  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const s = (method, params) => send(method, params, sessionId);
  handlers.push((m) => {
    if (m.sessionId !== sessionId) return;
    if (m.method === 'Runtime.exceptionThrown') problems.push(`exception: ${m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text}`);
    if (m.method === 'Runtime.consoleAPICalled' && (m.params.type === 'error' || m.params.type === 'assert')) {
      problems.push(`console.${m.params.type}: ${m.params.args.map((a) => a.value ?? a.description).join(' ')}`);
    }
    if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error') {
      const e = m.params.entry;
      // The mock has no icon for unknown apps (404) by design.
      if (!/\/api\/icon/.test(e.url ?? '')) problems.push(`log: ${e.text} ${e.url ?? ''}`);
    }
  });
  await s('Runtime.enable');
  await s('Log.enable');
  await s('Page.enable');
  await s('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 2, mobile: true });
  // Headless Chrome ignores --lang for navigator.languages; the Accept-Language override does not.
  const ua = (await s('Browser.getVersion')).userAgent;
  await s('Emulation.setUserAgentOverride', { userAgent: ua, acceptLanguage: flag('es') ? 'es-MX,es' : 'en-US,en' });
  await s('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  await s('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: flag('dark') ? 'dark' : 'light' }] });

  const evaluate = async (expr) => (await s('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })).result.value;
  const waitFor = async (expr, ms = 8000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (await evaluate(expr)) return true;
      await sleep(100);
    }
    throw new Error(`timeout waiting for ${expr}`);
  };
  const shot = async (name) => {
    await sleep(250);
    const { data } = await s('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(OUT, `${name}.png`), Buffer.from(data, 'base64'));
  };
  const click = (sel) => evaluate(`(() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e) return false; e.click(); return true; })()`);

  // 1. Pair.
  if (flag('approve')) {
    await s('Page.navigate', { url: `${BASE}/` });
    await waitFor(`!!document.querySelector('.pin-form .btn-link')`);
    await click('.pin-form .btn-link');
  } else if (PIN) {
    await s('Page.navigate', { url: `${BASE}/` });
    await waitFor(`!!document.querySelector('#pin-input')`);
    await shot('01-connect');
    await evaluate(`(() => { const i = document.querySelector('#pin-input'); i.value = ${JSON.stringify(PIN)}; i.dispatchEvent(new Event('input')); })()`);
  } else {
    const { code } = await (await fetch(`${BASE}/__mock/pairing`)).json();
    await s('Page.navigate', { url: `${BASE}/` });
    await waitFor(`!!document.querySelector('[data-screen=connect]')`);
    await shot('01-connect');
    await s('Page.navigate', { url: `${BASE}/#pair=${code}` });
  }
  await waitFor(`!!document.querySelector('[data-screen=shell]')`, 15000);
  if (await evaluate('location.hash.includes("pair=")')) problems.push('pair code left in the URL');
  await waitFor(`!!document.querySelector('.pad')`);
  await shot('02-trackpad');

  // Drag on the trackpad with a touch to produce Move frames.
  const box = await evaluate(`(() => { const r = document.querySelector('.pad').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
  await s('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: box.x, y: box.y }] });
  for (let i = 1; i <= 10; i++) {
    await s('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: box.x + i * 6, y: box.y + i * 3 }] });
    await sleep(16);
  }
  await s('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });

  // 2. Every tab.
  for (const [i, tab] of ['keyboard', 'deck', 'media', 'apps'].entries()) {
    await click(`#tab-${tab}`);
    await waitFor(`!!document.querySelector('#view-${tab}') && !document.querySelector('#view-${tab}').hidden`);
    await sleep(400);
    await shot(`0${i + 3}-${tab}`);
  }
  // Keyboard modes.
  await click('#tab-keyboard');
  for (const [i, label] of [0, 1, 2].entries()) {
    await evaluate(`document.querySelectorAll('#view-keyboard .seg-opt')[${label}].click()`);
    await sleep(300);
    await shot(`07-keyboard-mode-${i}`);
  }
  // Deck: run a tile and open the editor.
  await click('#tab-deck');
  await waitFor(`document.querySelectorAll('.tile').length > 0`);
  await click('.tile');
  await sleep(300);
  await evaluate(`document.querySelector('#view-deck .deck-head .icon-btn').click()`);
  await sleep(300);
  await shot('08-deck-edit');
  await click('.deck-grid.editing .tile-add');
  await sleep(400);
  await shot('09-tile-editor');
  await evaluate(`document.querySelector('.sheet .icon-btn').click()`);
  await sleep(300);
  await evaluate(`[...document.querySelectorAll('#view-deck .btn')].find((b) => b.textContent.length < 8)?.click()`);

  // Settings sheet.
  await evaluate(`document.querySelector('.statusbar .icon-btn:last-child').click()`);
  await waitFor(`!!document.querySelector('.sheet')`);
  await shot('10-settings');
  await evaluate(`document.querySelector('.sheet .icon-btn').click()`);
  await sleep(300);

  // 3. Reload: should come back with the stored token.
  await s('Page.reload');
  await waitFor(`!!document.querySelector('[data-screen=shell]')`, 15000);
  await shot('11-after-reload');

  const status = await evaluate(`document.querySelector('.mac-name')?.textContent`);
  console.log(`connected to: ${status}`);
}

try {
  await main();
} catch (err) {
  problems.push(`check failed: ${err.message}`);
} finally {
  ws?.close();
  chrome.kill();
  await sleep(200);
  rmSync(profile, { recursive: true, force: true });
}

console.log(`screenshots in ${OUT}`);
if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
console.log('no console errors');
