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

// --- caption markup ----------------------------------------------------------

// CSS named colours, accepted by <font color="...">.
const NAMED_COLORS = new Set(
  (
    "aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown " +
    "burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan " +
    "darkgoldenrod darkgray darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid " +
    "darkred darksalmon darkseagreen darkslateblue darkslategray darkslategrey darkturquoise darkviolet " +
    "deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite forestgreen fuchsia gainsboro " +
    "ghostwhite gold goldenrod gray green greenyellow grey honeydew hotpink indianred indigo ivory khaki " +
    "lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow " +
    "lightgray lightgreen lightgrey lightpink lightsalmon lightseagreen lightskyblue lightslategray " +
    "lightslategrey lightsteelblue lightyellow lime limegreen linen magenta maroon mediumaquamarine " +
    "mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen mediumturquoise " +
    "mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace olive olivedrab " +
    "orange orangered orchid palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru " +
    "pink plum powderblue purple rebeccapurple red rosybrown royalblue saddlebrown salmon sandybrown " +
    "seagreen seashell sienna silver skyblue slateblue slategray slategrey snow springgreen steelblue tan " +
    "teal thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen"
  ).split(" "),
);

function validColor(c) {
  return /^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i.test(c) || NAMED_COLORS.has(c.toLowerCase());
}

// The style an opening tag adds, or null if the tag is malformed. `attrs` is
// everything between the tag name and ">".
function flagTag(flag) {
  return (attrs) => (attrs.trim() === "" ? { [flag]: true } : null);
}

function fontTag(attrs) {
  if (attrs !== "" && !/^\s/.test(attrs)) {
    return null; // e.g. <fontx>
  }
  const m = /\bcolor\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"']+))/i.exec(attrs);
  const color = m ? (m[1] ?? m[2] ?? m[3]).trim() : "";
  return validColor(color) ? { color } : {};
}

const TAGS = { b: flagTag("b"), i: flagTag("i"), u: flagTag("u"), s: flagTag("s"), font: fontTag };

// A tag (<b>, </font>, <font color=red>) or an ASS override block ({\an8}).
const TOKEN = /<(\/?)([a-z]+)([^<>]*)>|\{\\([^{}]*)\}/gi;

// Effective style of the open-tag stack: flags are on if any open tag sets
// them; the innermost colour wins.
function styleOf(stack) {
  const st = {};
  for (const t of stack) {
    Object.assign(st, t.style);
  }
  return st;
}

function sameStyle(a, b) {
  return a.b === b.b && a.i === b.i && a.u === b.u && a.s === b.s && a.color === b.color;
}

function emit(out, text, stack) {
  if (text === "") {
    return;
  }
  const style = styleOf(stack);
  const last = out.spans[out.spans.length - 1];
  if (last && sameStyle(last, style)) {
    last.text += text;
  } else {
    out.spans.push(Object.assign({ text }, style));
  }
}

// Closes the innermost open `name`; returns false for a stray closer.
// Closing a tag that isn't innermost only drops that tag, so overlapping
// tags (<b>x<i>y</b>z</i>) still style what a reader would expect.
function closeTag(stack, name, attrs) {
  for (let i = stack.length - 1; i >= 0; i--) {
    if (stack[i].name === name && attrs.trim() === "") {
      stack.splice(i, 1);
      return true;
    }
  }
  return false;
}

function openTag(stack, name, attrs) {
  const tag = Object.prototype.hasOwnProperty.call(TAGS, name) ? TAGS[name] : null;
  const style = tag && tag(attrs);
  if (!style) {
    return false;
  }
  stack.push({ name, style });
  return true;
}

// Handles one matched token; returns false if it should stay literal text.
function applyToken(out, stack, m) {
  if (m[4] !== undefined) {
    const an = /\\an([1-9])/.exec("\\" + m[4]);
    if (an && out.align === null) {
      out.align = Number(an[1]);
    }
    return true;
  }
  const name = m[2].toLowerCase();
  return m[1] ? closeTag(stack, name, m[3]) : openTag(stack, name, m[3]);
}

// Parses SRT inline markup (<b> <i> <u> <s> <font color>, nestable, any case)
// into styled spans, and strips ASS override blocks, keeping the first {\anN}
// as `align` (numpad layout: 1-3 bottom, 4-6 middle, 7-9 top; default 2).
// Unknown or malformed tags and stray closers stay as literal text; unclosed
// tags run to the end of the cue.
function markup(text) {
  const out = { spans: [], align: null };
  const stack = [];
  const src = String(text || "");
  let at = 0;
  for (const m of src.matchAll(TOKEN)) {
    // a literal token just becomes part of the next run of text
    emit(out, src.slice(at, m.index), stack);
    at = m.index;
    if (applyToken(out, stack, m)) {
      at += m[0].length;
    }
  }
  emit(out, src.slice(at), stack);
  return { spans: out.spans, align: out.align || 2 };
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
  markup,
};
