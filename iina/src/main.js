// Main entry: one instance per player window. Reports playback to the global
// entry, runs commands it forwards, and renders previewed cues in an overlay.
const { core, mpv, event, overlay, global, console: log } = iina;
const P = require("./protocol.js");

const TIME_MS = 100; // min gap between time reports (~10 Hz)

const S = {
  clients: 0,
  trailing: false,
  lastPos: null,
  lastPaused: null,
  lastSentAt: 0,
  render: { sticky: null, items: [] },
  shown: undefined, // text currently in the overlay (undefined = unknown)
  overlayReady: false,
  hideSubs: true,
  savedSubVis: null,
  anchor: { pos: 0, at: 0, paused: true, speed: 1 },
  boundaryTimer: null,
  musicMode: false,
};

function post(msg) {
  global.postMessage("cueline:evt", msg);
}

function filePath() {
  const path = mpv.getString("path");
  return P.toPath(path || core.status.url);
}

function playback() {
  const st = core.status;
  // mpv's time-pos is current to the frame; core.status.position lags behind
  // IINA's UI refresh
  const pos = mpv.getNumber("time-pos");
  return { pos: Number.isFinite(pos) ? pos : st.position || 0, paused: st.paused, speed: st.speed };
}

function snapshot() {
  const st = core.status;
  return Object.assign(playback(), { file: st.idle ? null : filePath(), duration: st.duration });
}

// --- subtitle track hiding -------------------------------------------------

function hideSubs() {
  if (S.hideSubs && S.savedSubVis === null) {
    S.savedSubVis = mpv.getFlag("sub-visibility");
    mpv.set("sub-visibility", false);
  }
}

function restoreSubs() {
  if (S.savedSubVis !== null) {
    mpv.set("sub-visibility", S.savedSubVis);
    S.savedSubVis = null;
  }
}

// --- overlay ---------------------------------------------------------------

function showText(text) {
  if (!S.overlayReady) {
    return false;
  }
  // strings cross the overlay bridge URI-encoded so quotes, backslashes and
  // newlines arrive intact; the markup goes as encoded JSON for the same reason
  const src = text || "";
  overlay.postMessage("cue", { t: encodeURIComponent(src), m: encodeURIComponent(JSON.stringify(P.markup(src))) });
  if (text) {
    hideSubs();
  }
  return true;
}

function render(pos) {
  const text = P.pickText(S.render, pos);
  if (text !== S.shown && showText(text)) {
    S.shown = text;
  }
}

function setAnchor(pb) {
  S.anchor = { pos: pb.pos, at: Date.now(), paused: pb.paused, speed: pb.speed || 1 };
}

function estPos() {
  return P.estimate(S.anchor, Date.now());
}

// Re-render exactly at the next cue boundary instead of waiting for the next
// time-pos update, which can be ~0.5 s away for audio.
function scheduleBoundary(pos) {
  if (S.boundaryTimer) {
    clearTimeout(S.boundaryTimer);
    S.boundaryTimer = null;
  }
  const next = S.anchor.paused || S.clients === 0 ? null : P.nextBoundary(S.render, pos);
  if (next === null) {
    return;
  }
  const delay = Math.min(2000, Math.max(10, ((next - pos) / S.anchor.speed) * 1000 + 5));
  S.boundaryTimer = setTimeout(() => {
    S.boundaryTimer = null;
    renderNow();
  }, delay);
}

function renderNow() {
  const pos = estPos();
  render(pos);
  scheduleBoundary(pos);
}

function setupOverlay() {
  try {
    overlay.loadFile("overlay.html");
  } catch (e) {
    log.warn(`overlay not available yet: ${e}`);
  }
}

event.on("iina.window-loaded", setupOverlay);

event.on("iina.plugin-overlay-loaded", () => {
  overlay.onMessage("shown", (d) =>
    post({
      type: "shown",
      text: decodeURIComponent((d && d.t) || ""),
      rendered: decodeURIComponent((d && d.r) || ""),
      subs_hidden: S.savedSubVis !== null,
    }),
  );
  overlay.setClickable(false);
  overlay.show();
  S.overlayReady = true;
  S.shown = undefined;
  log.log("overlay ready");
});

// --- playback reporting ----------------------------------------------------

function postTime(pb) {
  S.lastPos = pb.pos;
  S.lastSentAt = Date.now();
  post(Object.assign({ type: "time" }, pb));
}

// Trailing report so the final position after a burst (e.g. a seek while
// paused) is never swallowed by the throttle.
function scheduleTrailing() {
  if (S.trailing) {
    return;
  }
  S.trailing = true;
  setTimeout(() => {
    S.trailing = false;
    const pb = playback();
    if (S.clients > 0 && pb.pos !== S.lastPos) {
      postTime(pb);
    }
  }, TIME_MS);
}

function reportTime(pb) {
  if (pb.paused !== S.lastPaused) {
    S.lastPaused = pb.paused;
    post(Object.assign({ type: "state" }, pb));
  }
  if (pb.pos === S.lastPos) {
    return;
  }
  if (Date.now() - S.lastSentAt >= TIME_MS) {
    postTime(pb);
  } else {
    scheduleTrailing();
  }
}

// Driven by mpv's time-pos property (every frame / audio chunk) rather than
// a JS timer: a 50 ms setInterval only managed ~5 Hz inside IINA in testing.
function onTimePos() {
  if (S.clients === 0 || core.status.idle) {
    return;
  }
  const pb = playback();
  setAnchor(pb);
  renderNow();
  reportTime(pb);
}

// The overlay lives on the video view, which music mode hides.
function noticeMusicMode() {
  if (S.musicMode) {
    post({
      type: "notice",
      message: "IINA is in music mode, so the cue caption is hidden; leave music mode to see it",
    });
  }
}

event.on("iina.music-mode.changed", (on) => {
  S.musicMode = Boolean(on);
  log.log(`music mode: ${S.musicMode}`);
  if (S.clients > 0) {
    noticeMusicMode();
  }
});

function setClients(n) {
  if (n !== S.clients) {
    log.log(`clients: ${n}`);
  }
  const was = S.clients;
  S.clients = n;
  if (n > 0 && was === 0) {
    S.lastPos = null;
    S.lastPaused = null;
    onTimePos();
    noticeMusicMode();
  } else if (n === 0 && was > 0) {
    commands.clear();
  }
}

event.on("mpv.time-pos.changed", onTimePos);

// --- commands from Neovim (via the global entry) ---------------------------

function seek(target, mode) {
  mpv.command("seek", [String(target), mode]);
}

const commands = {
  seek: (m) => {
    seek(Number(m.pos) || 0, "absolute+exact");
    if (m.play) {
      core.resume();
    }
  },
  // absolute from our own estimate: mpv's relative seeks on audio-only files
  // measured off by over a second
  nudge: (m) => seek(Math.max(0, estPos() + (Number(m.delta) || 0)), "absolute+exact"),
  "toggle-pause": () => (core.status.paused ? core.resume() : core.pause()),
  pause: () => core.pause(),
  play: () => core.resume(),
  speed: (m) => core.setSpeed(Number(m.speed) || 1),
  cue: (m) => {
    S.render = { sticky: m, items: S.render.items };
    renderNow();
  },
  cues: (m) => {
    S.render = { sticky: null, items: Array.isArray(m.items) ? m.items : [] };
    renderNow();
  },
  clear: () => {
    S.render = { sticky: null, items: [] };
    renderNow();
    restoreSubs();
  },
  config: (m) => {
    S.hideSubs = m.hide_subs !== false;
    if (!S.hideSubs) {
      restoreSubs();
    }
  },
  open: (m) => core.open(m.path),
};

// Handled on a fresh tick: messages this entry posts back to the global
// entry while still inside the global's postMessage call arrive mangled
// (their fields come through undefined).
global.onMessage("cueline:cmd", (msg) => setTimeout(() => P.dispatch(commands, msg), 0));
global.onMessage("cueline:clients", (n) => setTimeout(() => setClients(Number(n) || 0), 0));

// --- player events -----------------------------------------------------------

event.on("iina.file-loaded", () => {
  S.render = { sticky: null, items: [] };
  post(Object.assign({ type: "file" }, snapshot()));
});

event.on("mpv.pause.changed", () => {
  if (S.clients > 0) {
    const pb = playback();
    // for audio-only files mpv's time-pos can be ~0.5 s stale right here and
    // catch up afterwards; the running estimate is closer to where it stopped
    const est = estPos();
    const audioOnly = !core.status.videoWidth;
    if (audioOnly && pb.paused && !S.anchor.paused && Math.abs(est - pb.pos) < 1) {
      pb.pos = Math.max(pb.pos, est);
    }
    setAnchor(pb);
    renderNow();
    S.lastPaused = pb.paused;
    post(Object.assign({ type: "state" }, pb));
  }
});

event.on("iina.window-will-close", () => {
  restoreSubs();
  post({ type: "closed" });
});

// deferred: this instance isn't registered with its player until the entry
// finishes evaluating, and the global entry replies to it by label
setTimeout(() => post(Object.assign({ type: "hello-child" }, snapshot())), 0);
if (core.window.loaded) {
  setupOverlay();
}
log.log("cueline main entry loaded");
