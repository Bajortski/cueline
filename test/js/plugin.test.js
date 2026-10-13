// Runs the IINA entries (global.js + main.js) against a fake `iina` API to
// check routing, rendering and command handling without launching IINA.
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const P = require("../../iina/src/protocol.js");

const SRC = path.join(__dirname, "../../iina/src");

function addSubTrack(w, file) {
  const id = w.nextId++;
  w.tracks.push({ id, type: "sub", "external-filename": file });
  return id;
}

function removeSubTrack(w, id) {
  const i = w.tracks.findIndex((t) => String(t.id) === String(id));
  return i < 0 ? null : w.tracks.splice(i, 1)[0];
}

// What mpv does for the track commands main.js uses. sub-reload removes and
// re-adds the track, so it comes back with a new id (selection survives).
const MPV_SIM = {
  "sub-add": (w, file, flag) => {
    const id = addSubTrack(w, file);
    if (flag === "select") {
      w.props.sid = String(id);
    }
  },
  "sub-reload": (w, id) => {
    const old = removeSubTrack(w, id);
    const fresh = old && addSubTrack(w, old["external-filename"]);
    if (fresh && w.props.sid === String(id)) {
      w.props.sid = String(fresh);
    }
  },
  "sub-remove": (w, id) => {
    if (removeSubTrack(w, id) && w.props.sid === String(id)) {
      w.props.sid = "no";
    }
  },
};

function makeWorld() {
  const w = { delayed: [], sent: [], mpvCmds: [], overlay: [], markup: [], intervals: [], queue: [] };
  w.props = { "sub-visibility": true, sid: "1", "sub-text": "" };
  // mpv's track list, starting with a subtitle track of the user's own
  w.tracks = [{ id: 1, type: "sub", "external-filename": "/movies/own.srt" }];
  w.nextId = 2;
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
      getString: (k) => (k === "path" ? "/tmp/a b.mp4" : w.props[k]),
      getNative: (k) => (k === "track-list" ? w.tracks.map((t) => Object.assign({}, t)) : undefined),
      getFlag: (k) => w.props[k],
      getNumber: (k) => (k === "time-pos" ? w.status.position : 0),
      set: (k, v) => (w.props[k] = v),
      command: (name, args) => {
        w.mpvCmds.push([name, ...args]);
        if (MPV_SIM[name]) {
          MPV_SIM[name](w, ...args);
        }
      },
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
  w.disconnect = (conn = "c1") => {
    wsHandlers.connState(conn, "cancelled");
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

test("findSubTrack matches by path or file name", () => {
  const list = [
    { id: 1, type: "video" },
    { id: 2, type: "sub", "external-filename": "/movies/own.srt" },
    { id: 4, type: "sub", "external-filename": "/private/var/T/0-cueline.ass" },
  ];
  assert.strictEqual(P.findSubTrack(list, "/movies/own.srt"), 2);
  assert.strictEqual(P.findSubTrack(list, "/var/T/0-cueline.ass"), 4);
  assert.strictEqual(P.findSubTrack(list, "/var/T/other.ass"), null);
  assert.strictEqual(P.findSubTrack(undefined, "/x"), null);
});

const LIVE = "/var/T/0-cueline.ass";

function liveWorld() {
  const w = makeWorld();
  w.props["sub-visibility"] = false; // the user had subtitles switched off
  w.connect();
  w.fromClient({ type: "track", path: LIVE });
  return w;
}

test("track loads the file as a selected, visible subtitle track", () => {
  const w = liveWorld();
  assert.deepStrictEqual(w.mpvCmds.at(-1), ["sub-add", LIVE, "select", "cueline-live"]);
  assert.strictEqual(w.props.sid, "2");
  assert.strictEqual(w.props["sub-visibility"], true, "forced visible while live");
  const [, rep] = w.lastSent("track");
  assert.deepStrictEqual([rep.path, rep.id, rep.sid, rep.prev_sid], [LIVE, 2, "2", "1"]);
});

test("track for the same path reloads by the track's current id", () => {
  const w = liveWorld();
  w.fromClient({ type: "track", path: LIVE });
  assert.deepStrictEqual(w.mpvCmds.at(-1), ["sub-reload", "2"]);
  w.flush();
  assert.strictEqual(w.lastSent("track")[1].id, 3, "id changed on reload");
  w.fromClient({ type: "track", path: LIVE });
  assert.deepStrictEqual(w.mpvCmds.at(-1), ["sub-reload", "3"], "new id looked up, not cached");
  assert.strictEqual(w.props.sid, "4", "still selected");
  assert.strictEqual(w.mpvCmds.filter((c) => c[0] === "sub-add").length, 1);
});

test("sub-text changes are reported while live", () => {
  const w = liveWorld();
  w.props["sub-text"] = "Tonight we roll";
  w.status.position = 6;
  w.tick();
  w.fireDelayed();
  assert.strictEqual(w.lastSent("track")[1].text, "Tonight we roll");
  const n = w.sent.length;
  w.status.position = 6.1;
  w.tick();
  w.fireDelayed();
  const reports = (sent) => sent.filter(([, m]) => m.type === "track").length;
  assert.strictEqual(reports(w.sent), reports(w.sent.slice(0, n)), "unchanged text not re-sent");
});

test("the overlay stays empty and subs stay visible while live", () => {
  const w = liveWorld();
  w.status.position = 5;
  w.tick();
  w.fromClient({ type: "cues", items: [{ start: 4, end: 6, text: "plain" }] });
  w.fromClient({ type: "cue", start: 4, end: 6, text: "sticky", sticky: true });
  assert.ok(!w.overlay.includes("plain") && !w.overlay.includes("sticky"));
  assert.strictEqual(w.props["sub-visibility"], true);
});

test("track null removes our track and restores the user's sid and visibility", () => {
  const w = liveWorld();
  w.fromClient({ type: "track", path: LIVE }); // id 2 -> 3
  w.fromClient({ type: "track", path: null });
  assert.deepStrictEqual(w.mpvCmds.at(-1), ["sub-remove", "3"]);
  assert.strictEqual(w.props.sid, "1");
  assert.strictEqual(w.props["sub-visibility"], false);
  assert.deepStrictEqual(w.tracks.map((t) => t.id), [1]);
  const [, rep] = w.lastSent("track");
  assert.deepStrictEqual([rep.path, rep.id, rep.sid], [null, null, "1"]);
  w.status.position = 5;
  w.tick();
  w.fromClient({ type: "cues", items: [{ start: 4, end: 6, text: "srt again" }] });
  assert.strictEqual(w.overlay.at(-1), "srt again", "overlay back for SRT buffers");
});

test("a different path replaces the track; disconnect drops it", () => {
  const w = liveWorld();
  w.fromClient({ type: "track", path: "/var/T/1-cueline.ass" });
  assert.deepStrictEqual(w.tracks.map((t) => t["external-filename"]), ["/movies/own.srt", "/var/T/1-cueline.ass"]);
  assert.strictEqual(w.lastSent("track")[1].prev_sid, "1", "the user's sid, not ours");
  w.disconnect();
  assert.deepStrictEqual(w.tracks.map((t) => t.id), [1]);
  assert.strictEqual(w.props.sid, "1");
});
