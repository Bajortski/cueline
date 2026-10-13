// Runs the IINA entries (global.js + main.js) against a fake `iina` API to
// check routing, rendering and command handling without launching IINA.
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const P = require("../../iina/src/protocol.js");

const SRC = path.join(__dirname, "../../iina/src");

function makeWorld() {
  const w = { delayed: [], sent: [], mpvCmds: [], overlay: [], markup: [], props: { "sub-visibility": true }, intervals: [], queue: [] };
  const childListeners = {};
  const globalListeners = {};
  const wsHandlers = {};
  const events = {};
  w.status = { paused: false, idle: false, position: 0, duration: 60, speed: 1, url: "file:///tmp/a%20b.mp4" };

  const timers = {
    // zero-delay timers are thread hops; run them on flush(). Delayed ones
    // (cue-boundary re-renders) are kept aside and run by fireDelayed().
    setTimeout: (fn, ms) => (ms ? w.delayed.push(fn) : w.queue.push(fn)),
    clearTimeout: () => {},
    setInterval: (fn) => w.intervals.push(fn) && w.intervals.length,
    clearInterval: () => (w.intervals = []),
  };
  const log = { log() {}, warn() {}, error() {} };
  const prefs = { get: () => 10427 };

  const globalApi = {
    ws: {
      createServer: () => {},
      startServer: () => {},
      onStateUpdate: (h) => (wsHandlers.state = h),
      onNewConnection: (h) => (wsHandlers.conn = h),
      onConnectionStateUpdate: (h) => (wsHandlers.connState = h),
      onMessage: (h) => (wsHandlers.msg = h),
      sendText: (conn, text) => {
        w.sent.push([conn, JSON.parse(text)]);
        return Promise.resolve("success");
      },
    },
    global: {
      postMessage: (label, name, data) => childListeners[name] && childListeners[name](data),
      onMessage: (name, cb) => (globalListeners[name] = cb),
    },
    console: log,
    preferences: prefs,
  };
  const mainApi = {
    core: {
      status: w.status,
      window: { loaded: true },
      pause: () => (w.status.paused = true),
      resume: () => (w.status.paused = false),
      setSpeed: (s) => (w.status.speed = s),
      open: (p) => w.mpvCmds.push(["open", p]),
    },
    mpv: {
      getString: () => "/tmp/a b.mp4",
      getFlag: (k) => w.props[k],
      getNumber: (k) => (k === "time-pos" ? w.status.position : 0),
      set: (k, v) => (w.props[k] = v),
      command: (name, args) => w.mpvCmds.push([name, ...args]),
    },
    event: { on: (name, cb) => (events[name] = cb) },
    overlay: {
      loadFile: () => {},
      onMessage: (name, cb) => (w.overlayListener = cb),
      postMessage: (name, data) => {
        const text = decodeURIComponent(data.t);
        w.overlay.push(text);
        w.markup.push(JSON.parse(decodeURIComponent(data.m)));
        w.overlayListener({ t: encodeURIComponent(text) });
      },
      setClickable: () => {},
      show: () => {},
    },
    global: {
      postMessage: (name, data) => globalListeners[name] && globalListeners[name](data, "player-1"),
      onMessage: (name, cb) => (childListeners[name] = cb),
    },
    console: log,
  };

  function run(file, api) {
    const ctx = vm.createContext({ iina: api, require: () => P, ...timers, console });
    vm.runInContext(fs.readFileSync(path.join(SRC, file), "utf8"), ctx, { filename: file });
  }
  w.flush = () => {
    while (w.queue.length) w.queue.shift()();
  };
  run("global.js", globalApi);
  run("main.js", mainApi);
  w.flush();
  events["iina.plugin-overlay-loaded"]();
  w.tick = () => events["mpv.time-pos.changed"]();
  w.fireDelayed = () => {
    w.delayed.splice(0).forEach((f) => f());
    w.flush();
  };
  w.connect = (conn = "c1", pathDesc = "127.0.0.1:5000") => {
    wsHandlers.conn(conn, { path: pathDesc });
    wsHandlers.connState(conn, "ready");
    w.flush();
  };
  w.fromClient = (msg, conn = "c1") => {
    wsHandlers.msg(conn, { text: () => JSON.stringify(msg) });
    w.flush();
  };
  w.lastSent = (type) => [...w.sent].reverse().find(([, m]) => m.type === type);
  w.events = events;
  return w;
}

test("protocol helpers", () => {
  assert.strictEqual(P.parse("nope"), null);
  assert.strictEqual(P.parse('{"x":1}'), null);
  assert.deepStrictEqual(P.parse('{"type":"seek","pos":3}'), { type: "seek", pos: 3 });
  const render = { sticky: null, items: [{ start: 1, end: 2, text: "a" }, { start: 3, end: 4, text: "" }] };
  assert.strictEqual(P.pickText(render, 1.5), "a");
  assert.strictEqual(P.pickText(render, 2.5), null);
  assert.strictEqual(P.pickText(render, 3.5), "");
  assert.strictEqual(P.pickText({ sticky: { text: "s" }, items: render.items }, 1.5), "s");
  assert.strictEqual(P.nextBoundary(render, 0), 1);
  assert.strictEqual(P.nextBoundary(render, 1.5), 2);
  assert.strictEqual(P.nextBoundary(render, 4), null);
  assert.strictEqual(P.nextBoundary({ sticky: { text: "s" }, items: render.items }, 0), null);
  assert.strictEqual(P.estimate({ pos: 10, at: 0, paused: false, speed: 2 }, 500), 11);
  assert.strictEqual(P.estimate({ pos: 10, at: 0, paused: true, speed: 2 }, 500), 10);
  assert.strictEqual(P.toPath("file:///tmp/a%20b.m4a"), "/tmp/a b.m4a");
  assert.ok(P.isLoopback("127.0.0.1:1234"));
  assert.ok(P.isLoopback("::1.1234"));
  assert.ok(!P.isLoopback("192.168.1.20:1234"));
});

test("client lifecycle, hello and time reports", () => {
  const w = makeWorld();
  w.status.position = 3;
  w.tick();
  w.flush();
  assert.strictEqual(w.lastSent("time"), undefined, "no reports without clients");
  w.connect();
  w.fromClient({ type: "hello", client: "test" });
  const [, hello] = w.lastSent("hello");
  assert.strictEqual(hello.player.file, "/tmp/a b.mp4");
  w.status.position = 12.5;
  w.tick();
  w.fireDelayed(); // throttled -> trailing report
  assert.strictEqual(w.lastSent("time")[1].pos, 12.5);
});

test("non-loopback clients are ignored", () => {
  const w = makeWorld();
  w.connect("evil", "10.0.0.5:4444");
  w.fromClient({ type: "hello" }, "evil");
  assert.strictEqual(w.sent.length, 0);
});

test("commands reach mpv", () => {
  const w = makeWorld();
  w.connect();
  w.fromClient({ type: "seek", pos: 42.25, play: true });
  w.flush();
  assert.deepStrictEqual(w.mpvCmds.at(-1), ["seek", "42.25", "absolute+exact"]);
  w.status.position = 10;
  w.status.paused = true;
  w.tick();
  w.fromClient({ type: "nudge", delta: -2 });
  assert.deepStrictEqual(w.mpvCmds.at(-1), ["seek", "8", "absolute+exact"]);
  w.status.paused = false;
  w.fromClient({ type: "toggle-pause" });
  assert.strictEqual(w.status.paused, true);
  w.fromClient({ type: "bogus" });
  assert.match(w.lastSent("error")[1].message, /unknown/);
});

test("cue rendering, sub hiding and restore", () => {
  const w = makeWorld();
  w.connect();
  w.status.position = 5;
  w.tick();
  w.fromClient({ type: "cues", items: [{ start: 4, end: 6, text: "line `one` ${x}\nline two" }] });
  assert.strictEqual(w.overlay.at(-1), "line `one` ${x}\nline two");
  assert.strictEqual(w.props["sub-visibility"], false, "IINA subs hidden");
  w.flush();
  assert.strictEqual(w.lastSent("shown")[1].text, "line `one` ${x}\nline two");
  assert.strictEqual(w.delayed.length > 0, true, "re-render scheduled for the cue end");
  w.status.position = 6.5;
  w.tick();
  assert.strictEqual(w.overlay.at(-1), "", "hidden outside the cue");
  w.fromClient({ type: "cue", start: 1, end: 2, text: "sticky", sticky: true });
  assert.strictEqual(w.overlay.at(-1), "sticky");
  w.fromClient({ type: "cue", start: 1, end: 2, text: "{\\an8}<i>it</i>", sticky: true });
  assert.strictEqual(w.overlay.at(-1), "{\\an8}<i>it</i>", "source text still sent for the echo");
  assert.deepStrictEqual(w.markup.at(-1), { spans: [{ text: "it", i: true }], align: 8 });
  w.fromClient({ type: "clear" });
  assert.strictEqual(w.overlay.at(-1), "");
  assert.strictEqual(w.props["sub-visibility"], true, "IINA subs restored");
});

test("music mode produces a notice for clients", () => {
  const w = makeWorld();
  w.events["iina.music-mode.changed"](true);
  w.connect();
  assert.match(w.lastSent("notice")[1].message, /music mode/);
});
