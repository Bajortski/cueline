// Pure helpers shared by the IINA entries (and unit-tested under node).

const VERSION = "0.1.0";
const DEFAULT_PORT = 10427;

// Messages from nvim that the global entry forwards to the active player.
const PLAYER_COMMANDS = new Set([
  "seek",
  "nudge",
  "toggle-pause",
  "pause",
  "play",
  "speed",
  "cue",
  "cues",
  "clear",
  "config",
  "open",
]);

function parse(text) {
  try {
    const msg = JSON.parse(text);
    if (msg && typeof msg === "object" && typeof msg.type === "string") {
      return msg;
    }
  } catch {
    // not JSON
  }
  return null;
}

// Look up a handler by msg.type and run it. Returns false if unhandled.
function dispatch(table, msg, ...rest) {
  const handler = msg && Object.prototype.hasOwnProperty.call(table, msg.type) ? table[msg.type] : null;
  if (!handler) {
    return false;
  }
  handler(msg, ...rest);
  return true;
}

// The text to render at `pos`: a sticky preview wins, otherwise whichever
// windowed cue contains pos. null means "show nothing".
function pickText(render, pos) {
  if (render.sticky) {
    return render.sticky.text || "";
  }
  const items = render.items || [];
  for (let i = 0; i < items.length; i++) {
    const c = items[i];
    if (pos >= c.start && pos < c.end) {
      return c.text || "";
    }
  }
  return null;
}

// Next time after `pos` at which pickText's answer can change, or null.
function nextBoundary(render, pos) {
  if (render.sticky) {
    return null;
  }
  let next = Infinity;
  for (const c of render.items || []) {
    const t = c.start > pos ? c.start : c.end;
    if (t > pos && t < next) {
      next = t;
    }
  }
  return next === Infinity ? null : next;
}

// Estimated playback position `nowMs` given the last observed anchor
// { pos, at (ms), paused, speed }. mpv only updates time-pos every few
// hundred ms for audio-only files, so extrapolate between updates.
function estimate(anchor, nowMs) {
  if (anchor.paused) {
    return anchor.pos;
  }
  return anchor.pos + ((nowMs - anchor.at) / 1000) * (anchor.speed || 1);
}

// mpv's `path` is a plain path for local files; IINA's status.url is a
// file:// URL. Normalise either to a filesystem path.
function toPath(pathOrUrl) {
  if (!pathOrUrl) {
    return null;
  }
  if (pathOrUrl.startsWith("file://")) {
    return decodeURIComponent(pathOrUrl.slice(7));
  }
  return pathOrUrl;
}

// Network.framework debug descriptions look like "127.0.0.1:52344" or
// "::1.52344"; unknown (null) is treated as local since the path is not
// always resolved when the connection is announced.
function isLoopback(desc) {
  if (!desc) {
    return true;
  }
  return /^(127\.|::1|\[::1\]|localhost|::ffff:127\.)/.test(desc);
}

function hello(player) {
  return { type: "hello", server: "cueline-iina", version: VERSION, player: player || null };
}

module.exports = {
  VERSION,
  DEFAULT_PORT,
  PLAYER_COMMANDS,
  parse,
  dispatch,
  pickText,
  nextBoundary,
  estimate,
  toPath,
  isLoopback,
  hello,
};
