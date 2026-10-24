#!/usr/bin/env node
// End-to-end protocol checks against a running remoto-dev.
//
//   swift run remoto-dev --approve            # in one terminal
//   node tools/ws-e2e.mjs [--url http://127.0.0.1:7979] [--slow]
//
// Uses only Node 22 built-ins (global WebSocket, fetch, node:net).
// Approval-based pairing needs --approve on the server. --slow adds the
// 9-second silence watchdog check.

import net from "node:net";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const BASE = opt("--url", "http://127.0.0.1:7979").replace(/\/$/, "");
const WS = BASE.replace(/^http/, "ws") + "/ws";
const SLOW = args.includes("--slow");
const url = new URL(BASE);

let failures = 0;
const results = [];

async function check(name, fn) {
  try {
    await fn();
    console.log(`OK    ${name}`);
    results.push([name, true]);
  } catch (err) {
    failures++;
    console.log(`FAIL  ${name}: ${err?.message ?? err}`);
    results.push([name, false]);
  }
}

function assert(cond, message) {
  if (!cond) throw new Error(message);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const deviceId = (tag) => `e2e-${tag}-${Math.random().toString(36).slice(2, 10)}`;

// A WebSocket with a message queue.
function open() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS);
    ws.binaryType = "arraybuffer";
    const queue = [];
    const waiters = [];
    let closed = false;
    let closeResolve;
    const closedPromise = new Promise((r) => (closeResolve = r));
    ws.onmessage = (ev) => {
      const msg = typeof ev.data === "string" ? { raw: ev.data, ...JSON.parse(ev.data) } : { binary: ev.data };
      const w = waiters.shift();
      if (w) w.resolve(msg);
      else queue.push(msg);
    };
    ws.onclose = () => {
      closed = true;
      closeResolve();
      while (waiters.length) waiters.shift().resolve(null);
    };
    ws.onerror = () => {};
    const conn = {
      ws,
      send: (obj) => ws.send(typeof obj === "string" ? obj : JSON.stringify(obj)),
      sendBinary: (bytes) => ws.send(bytes),
      get closed() {
        return closed;
      },
      closedPromise,
      // Next message, or null if the socket closed, or throws on timeout.
      next(timeout = 3000) {
        if (queue.length) return Promise.resolve(queue.shift());
        if (closed) return Promise.resolve(null);
        return new Promise((resolveNext, rejectNext) => {
          const entry = { resolve: (m) => (clearTimeout(timer), resolveNext(m)) };
          const timer = setTimeout(() => {
            const i = waiters.indexOf(entry);
            if (i >= 0) waiters.splice(i, 1);
            rejectNext(new Error(`no message within ${timeout} ms`));
          }, timeout);
          waiters.push(entry);
        });
      },
      // Next message with this `t`, skipping others.
      async expect(t, timeout = 3000) {
        const deadline = Date.now() + timeout;
        while (true) {
          const left = deadline - Date.now();
          if (left <= 0) throw new Error(`no ${t} within ${timeout} ms`);
          const m = await conn.next(left);
          if (m === null) throw new Error(`socket closed while waiting for ${t}`);
          if (m.t === t) return m;
        }
      },
      // Resolves true if nothing arrives in `ms`.
      async quiet(ms, ignore = ["pong"]) {
        const deadline = Date.now() + ms;
        while (Date.now() < deadline) {
          try {
            const m = await conn.next(deadline - Date.now());
            if (m && !ignore.includes(m.t)) return m;
            if (m === null) return null;
          } catch {
            return true;
          }
        }
        return true;
      },
      close: () => ws.close(),
    };
    ws.onopen = () => resolve(conn);
    setTimeout(() => reject(new Error("WebSocket did not open")), 5000);
  });
}

function hello(id, auth, extra = {}) {
  return { t: "hello", v: 1, device: { id, name: "E2E phone", model: "Browser" }, auth, remember: false, ...extra };
}

// Raw HTTP request over TCP, returns { status, headers, raw }.
function rawRequest(text) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(Number(url.port || 80), url.hostname, () => sock.write(text));
    let data = "";
    sock.on("data", (d) => {
      data += d.toString("latin1");
      if (data.includes("\r\n\r\n")) sock.end();
    });
    sock.on("end", () => {
      const [head] = data.split("\r\n\r\n");
      const lines = head.split("\r\n");
      const status = Number(lines[0]?.split(" ")[1]);
      const headers = {};
      for (const l of lines.slice(1)) {
        const i = l.indexOf(":");
        if (i > 0) headers[l.slice(0, i).toLowerCase()] = l.slice(i + 1).trim();
      }
      resolve({ status, headers, raw: data });
    });
    sock.on("error", reject);
    setTimeout(() => (sock.destroy(), reject(new Error("raw request timed out"))), 5000);
  });
}

const host = url.host;
const wsHeaders = (extra = "") =>
  `GET /ws HTTP/1.1\r\nHost: ${host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
  `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n${extra}\r\n`;

const EXPECTED_CSP =
  "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' ws: wss:; worker-src 'self'; manifest-src 'self'; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

// ---------------------------------------------------------------------------

await check("GET /api/info has name, protocol, secure, version in order", async () => {
  const res = await fetch(`${BASE}/api/info`);
  assert(res.status === 200, `status ${res.status}`);
  assert(res.headers.get("cache-control") === "no-store", "Cache-Control");
  assert(res.headers.get("content-security-policy") === EXPECTED_CSP, "CSP");
  const text = await res.text();
  assert(Object.keys(JSON.parse(text)).join(",") === "name,protocol,secure,version", text);
  assert(JSON.parse(text).protocol === 1, "protocol");
});

await check("POST / is 405, foreign Host is 421", async () => {
  const post = await rawRequest(`POST / HTTP/1.1\r\nHost: ${host}\r\nContent-Length: 0\r\n\r\n`);
  assert(post.status === 405, `POST ${post.status}`);
  const evil = await rawRequest(`GET / HTTP/1.1\r\nHost: evil.example.com\r\n\r\n`);
  assert(evil.status === 421, `evil ${evil.status}`);
});

await check("/ws without Upgrade is 426, version 12 is 400, foreign Origin is 403", async () => {
  const plain = await rawRequest(`GET /ws HTTP/1.1\r\nHost: ${host}\r\n\r\n`);
  assert(plain.status === 426, `plain ${plain.status}`);
  const v12 = await rawRequest(wsHeaders("Sec-WebSocket-Version: 12\r\n"));
  assert(v12.status === 400 && v12.headers["sec-websocket-version"] === "13", `v12 ${v12.status}`);
  const origin = await rawRequest(wsHeaders("Sec-WebSocket-Version: 13\r\nOrigin: http://other:8740\r\n"));
  assert(origin.status === 403, `origin ${origin.status}`);
  const ok = await rawRequest(wsHeaders(`Sec-WebSocket-Version: 13\r\nOrigin: http://${host}\r\n`));
  assert(ok.status === 101, `same origin ${ok.status}`);
});

await check("first message ping -> bye{reconnect:false}", async () => {
  const c = await open();
  c.send({ t: "ping", id: 1 });
  const m = await c.next();
  assert(m?.t === "bye" && m.reconnect === false, JSON.stringify(m));
  await c.closedPromise;
});

await check("hello v:2 -> denied incompatible", async () => {
  const c = await open();
  c.send({ ...hello(deviceId("v2"), { method: "approve" }), v: 2 });
  const m = await c.next();
  assert(m?.t === "denied" && m.reason === "incompatible" && !("retryAfter" in m), JSON.stringify(m));
});

await check("device.id with a space or 129 bytes -> incompatible", async () => {
  for (const id of ["has space", "x".repeat(129)]) {
    const c = await open();
    c.send(hello(id, { method: "approve" }));
    const m = await c.next();
    assert(m?.t === "denied" && m.reason === "incompatible", `${id.length}: ${JSON.stringify(m)}`);
  }
});

await check("unknown token -> denied unknown", async () => {
  const c = await open();
  c.send(hello(deviceId("tok"), { method: "token", token: "nope" }));
  const m = await c.next();
  assert(m?.t === "denied" && m.reason === "unknown", JSON.stringify(m));
});

await check("bad pairing code -> denied expiredCode", async () => {
  const c = await open();
  c.send(hello(deviceId("pair"), { method: "pair", code: "AAAAAAAAAAAAAAAAAAAAAAAA" }));
  const m = await c.next();
  assert(m?.t === "denied" && m.reason === "expiredCode", JSON.stringify(m));
});

let token = null;
const rememberedId = deviceId("remembered");

await check("approve -> pending -> welcome with 43-char token and normative field order", async () => {
  const c = await open();
  c.send({ ...hello(rememberedId, { method: "approve" }), remember: true });
  const pending = await c.next(5000);
  assert(pending?.t === "pending", `expected pending, got ${JSON.stringify(pending)} (is remoto-dev running with --approve?)`);
  const w = await c.expect("welcome", 10000);
  assert(typeof w.token === "string" && w.token.length === 43, `token ${w.token}`);
  const keys = Object.keys(JSON.parse(w.raw));
  const order = ["t", "v", "host", "sessionKey", "token", "features", "deck", "layout", "volume", "paused", "settings"];
  const filtered = order.filter((k) => keys.includes(k));
  assert(keys.join(",") === filtered.join(","), `order ${keys.join(",")}`);
  assert(w.host.os === "macOS", "host.os");
  assert(Object.keys(w.features).join(",") === "voice,shell,secure,permission", "features");
  token = w.token;
  c.close();
});

await check("reconnect with token -> welcome with token null", async () => {
  assert(token, "no token from previous case");
  const c = await open();
  c.send(hello(rememberedId, { method: "token", token }, { device: { id: rememberedId, name: "Renamed phone", model: "Browser" } }));
  const w = await c.expect("welcome");
  assert(w.token === null, `token ${w.token}`);
  c.close();
});

await check("token with another device.id -> denied unknown", async () => {
  const c = await open();
  c.send(hello(deviceId("other"), { method: "token", token }));
  const m = await c.next();
  assert(m?.t === "denied" && m.reason === "unknown", JSON.stringify(m));
});

async function session() {
  const c = await open();
  c.send(hello(rememberedId, { method: "token", token }));
  const w = await c.expect("welcome");
  return { c, w };
}

await check("ping{id:'x'} -> pong{id:'x'}; ping{id:{a:[1,2.50]}} echoes exactly", async () => {
  const { c } = await session();
  c.send({ t: "ping", id: "x" });
  const p = await c.expect("pong");
  assert(p.id === "x", JSON.stringify(p));
  c.send('{"t":"ping","id":{"a":[1,2.50]}}');
  const p2 = await c.expect("pong");
  assert(p2.raw === '{"t":"pong","id":{"a":[1,2.50]}}', p2.raw);
  c.close();
});

await check("malformed JSON and bad binary frames keep the session open", async () => {
  const { c } = await session();
  c.send("{not json");
  c.send({ t: "nope" });
  c.sendBinary(new Uint8Array([0x01, 0, 0, 0, 0, 0, 0, 0])); // Move with 8 bytes
  const nan = new DataView(new ArrayBuffer(9));
  nan.setUint8(0, 0x01);
  nan.setFloat32(1, NaN, true);
  c.sendBinary(nan.buffer);
  c.send({ t: "ping", id: 7 });
  const p = await c.expect("pong");
  assert(p.id === 7 && !c.closed, "session closed");
  c.close();
});

await check("action without id succeeds silently; with id returns actionResult ok", async () => {
  const { c } = await session();
  c.send({ t: "action", action: { kind: "media", key: "playPause" } });
  c.send({ t: "action", action: { kind: "keys", code: 8, mods: 1, char: "c" }, id: 41 });
  const r = await c.expect("actionResult");
  assert(r.id === 41 && r.ok === true && !("message" in r), JSON.stringify(r));
  c.close();
});

await check("invalid actions fail at once: 4-level sequence, 65 steps, keys code 0x100", async () => {
  const { c } = await session();
  const nest = (n) => (n === 0 ? { kind: "delay", ms: 1 } : { kind: "sequence", steps: [nest(n - 1)] });
  c.send({ t: "action", action: nest(4), id: "deep" });
  const deep = await c.expect("actionResult");
  assert(deep.id === "deep" && deep.ok === false, JSON.stringify(deep));
  c.send({ t: "action", action: nest(3), id: "ok3" });
  const ok3 = await c.expect("actionResult");
  assert(ok3.id === "ok3" && ok3.ok === true, JSON.stringify(ok3));
  const steps = Array.from({ length: 65 }, () => ({ kind: "delay", ms: 0 }));
  c.send({ t: "action", action: { kind: "sequence", steps }, id: "65" });
  const many = await c.expect("actionResult");
  assert(many.ok === false, JSON.stringify(many));
  c.send({ t: "action", action: { kind: "keys", code: 256 }, id: "key" });
  const key = await c.expect("actionResult");
  assert(key.ok === false, JSON.stringify(key));
  c.close();
});

await check("url javascript:/data: fail, file: fails without shell, https: opens", async () => {
  const { c } = await session();
  for (const [u, ok] of [
    ["javascript:alert(1)", false],
    ["JavaScript:alert(1)", false],
    ["data:text/html,hi", false],
    ["file:///etc/hosts", false],
    ["https://example.com", true],
  ]) {
    c.send({ t: "action", action: { kind: "url", url: u }, id: u });
    const r = await c.expect("actionResult");
    assert(r.id === u && r.ok === ok, `${u}: ${JSON.stringify(r)}`);
  }
  c.close();
});

await check("shell is refused while allowShell is false", async () => {
  const { c } = await session();
  c.send({ t: "action", action: { kind: "shell", command: "true" }, id: 1 });
  const r = await c.expect("actionResult");
  assert(r.ok === false && typeof r.message === "string", JSON.stringify(r));
  c.close();
});

await check("deckSave with 9 columns -> notice deck; valid deck is broadcast", async () => {
  const a = await session();
  const b = await session();
  const deck = structuredClone(a.w.deck);
  const bad = structuredClone(deck);
  bad.pages[0].columns = 9;
  a.c.send({ t: "deckSave", deck: bad });
  const n = await a.c.expect("notice");
  assert(n.level === "error" && n.code === "deck", JSON.stringify(n));
  deck.pages[0].name = "E2E " + Date.now();
  a.c.send({ t: "deckSave", deck });
  const da = await a.c.expect("deck");
  const db = await b.c.expect("deck");
  assert(da.deck.pages[0].name === deck.pages[0].name && db.deck.pages[0].name === deck.pages[0].name, "broadcast");
  // Put the default name back.
  deck.pages[0].name = a.w.deck.pages[0].name;
  a.c.send({ t: "deckSave", deck });
  await a.c.expect("deck");
  a.c.close();
  b.c.close();
});

await check("text of 65537 bytes -> notice tooLong", async () => {
  const { c } = await session();
  c.send({ t: "text", text: "a".repeat(65537) });
  const n = await c.expect("notice");
  assert(n.level === "warning" && n.code === "tooLong", JSON.stringify(n));
  c.close();
});

await check("clipboardSet then clipboardGet round-trips", async () => {
  const { c } = await session();
  c.send({ t: "clipboardSet", text: "hello e2e" });
  await sleep(100);
  c.send({ t: "clipboardGet" });
  const m = await c.expect("clipboard");
  assert(m.text === "hello e2e", JSON.stringify(m));
  c.close();
});

await check("apps returns a list", async () => {
  const { c } = await session();
  c.send({ t: "apps" });
  const m = await c.expect("apps");
  assert(Array.isArray(m.apps), JSON.stringify(m));
  if (m.apps[0]) assert(Object.keys(m.apps[0]).join(",") === "id,name,running,active,hidden", "app keys");
  c.close();
});

await check("settingsSave is stored and comes back in the next welcome", async () => {
  const { c } = await session();
  const updatedAt = Date.now();
  c.send({ t: "settingsSave", settings: { pointerSpeed: 1.5, e2e: updatedAt }, updatedAt });
  await sleep(150);
  c.send({ t: "settingsSave", settings: "nope", updatedAt: updatedAt + 1 });
  const n = await c.expect("notice");
  assert(n.level === "error", JSON.stringify(n));
  c.close();
  const again = await session();
  assert(again.w.settings?.updatedAt === updatedAt && again.w.settings.settings.e2e === updatedAt, JSON.stringify(again.w.settings));
  again.c.send({ t: "settingsList" });
  const list = await again.c.expect("settingsList");
  assert(!list.devices.some((d) => d.id === rememberedId), "own device listed");
  again.c.close();
});

await check("settingsCopy from a session that isn't remembered -> notice settings", async () => {
  const c = await open();
  c.send(hello(deviceId("guest"), { method: "approve" }));
  await c.expect("welcome", 10000);
  c.send({ t: "settingsCopy", from: rememberedId });
  const n = await c.expect("notice");
  assert(n.level === "warning" && n.code === "settings", JSON.stringify(n));
  c.close();
});

await check("voiceStart answers with a voice message", async () => {
  const { c } = await session();
  c.send({ t: "voiceStart", locale: "en-US" });
  const v = await c.expect("voice");
  assert(["listening", "unavailable"].includes(v.state) && "final" in v, JSON.stringify(v));
  c.send({ t: "voiceStop" });
  c.close();
});

if (SLOW) {
  await check("9 s without frames closes the session without bye", async () => {
    const { c } = await session();
    const m = await c.quiet(10000, []);
    assert(m === null && c.closed, `got ${JSON.stringify(m)}`);
  });

  await check("ping every 2 s keeps the session open past 9 s", async () => {
    const { c } = await session();
    for (let i = 0; i < 5; i++) {
      c.send({ t: "ping", id: i });
      await c.expect("pong");
      await sleep(2000);
    }
    assert(!c.closed, "closed");
    c.close();
  });
}

console.log(`\n${results.length - failures}/${results.length} passed`);
process.exit(failures ? 1 : 0);
