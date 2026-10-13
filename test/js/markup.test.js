// SRT inline markup parsing, and the overlay page rendering it into a fake DOM.
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { markup } = require("../../iina/src/protocol.js");

const spans = (text) => markup(text).spans;

test("plain text is one unstyled span", () => {
  assert.deepStrictEqual(markup("hello"), { spans: [{ text: "hello" }], align: 2 });
  assert.deepStrictEqual(markup(""), { spans: [], align: 2 });
  assert.deepStrictEqual(markup(null), { spans: [], align: 2 });
});

test("newlines are kept in span text", () => {
  assert.deepStrictEqual(spans("one\n<b>two</b>\nthree"), [{ text: "one\n" }, { text: "two", b: true }, { text: "\nthree" }]);
});

test("tags nest and are case-insensitive", () => {
  assert.deepStrictEqual(spans("a<B>b<i>c<U>d<s>e</S></u></I>f</b>g"), [
    { text: "a" },
    { text: "b", b: true },
    { text: "c", b: true, i: true },
    { text: "d", b: true, i: true, u: true },
    { text: "e", b: true, i: true, u: true, s: true },
    { text: "f", b: true },
    { text: "g" },
  ]);
  // overlapping tags drop only the one that closed
  assert.deepStrictEqual(spans("<b>x<i>y</b>z</i>"), [
    { text: "x", b: true },
    { text: "y", b: true, i: true },
    { text: "z", i: true },
  ]);
});

test("font colours: quoted, unquoted, hex, named, nested", () => {
  assert.deepStrictEqual(spans('<font color="#ff0000">r</font>'), [{ text: "r", color: "#ff0000" }]);
  assert.deepStrictEqual(spans("<font color=#0f0>g</font>"), [{ text: "g", color: "#0f0" }]);
  assert.deepStrictEqual(spans("<FONT COLOR='Yellow'>y</FONT>"), [{ text: "y", color: "Yellow" }]);
  assert.deepStrictEqual(spans('<font color="red">a<font color="blue">b</font>c</font>'), [
    { text: "a", color: "red" },
    { text: "b", color: "blue" },
    { text: "c", color: "red" },
  ]);
  assert.deepStrictEqual(spans('<font face="x" color="teal"><b>t</b></font>'), [{ text: "t", b: true, color: "teal" }]);
});

test("invalid font colours are ignored, the tag still consumed", () => {
  for (const bad of ['"#ff00"', '"red;background:url(x)"', '"notacolour"', '"rgb(1,2,3)"', '"#gggggg"', '""']) {
    assert.deepStrictEqual(spans(`<font color=${bad}>x</font>`), [{ text: "x" }], bad);
  }
  assert.deepStrictEqual(spans("<font>x</font>"), [{ text: "x" }]);
});

test("unknown and malformed tags stay literal", () => {
  assert.deepStrictEqual(spans("<c.yellow>x</c>"), [{ text: "<c.yellow>x</c>" }]);
  assert.deepStrictEqual(spans("<span>x</span>"), [{ text: "<span>x</span>" }]);
  assert.deepStrictEqual(spans("<b x>y</b>"), [{ text: "<b x>y</b>" }]);
  assert.deepStrictEqual(spans("<fontx>y"), [{ text: "<fontx>y" }]);
  assert.deepStrictEqual(spans("<b"), [{ text: "<b" }]);
  assert.deepStrictEqual(spans("<i>a<b</i>"), [{ text: "a<b", i: true }]);
});

test("unclosed tags run to the end, stray closers are literal", () => {
  assert.deepStrictEqual(spans("a<i>b\nc"), [{ text: "a" }, { text: "b\nc", i: true }]);
  assert.deepStrictEqual(spans("a</b>c"), [{ text: "a</b>c" }]);
  assert.deepStrictEqual(spans("<i>a</i></i>b"), [{ text: "a", i: true }, { text: "</i>b" }]);
});

test("< and > as plain text", () => {
  assert.deepStrictEqual(spans("a < b"), [{ text: "a < b" }]);
  assert.deepStrictEqual(spans("a < b > c"), [{ text: "a < b > c" }]);
  assert.deepStrictEqual(spans("1<2 and 3>2"), [{ text: "1<2 and 3>2" }]);
  assert.deepStrictEqual(spans("<3 <b>love</b>"), [{ text: "<3 " }, { text: "love", b: true }]);
});

test("ASS override blocks are stripped and {\\anN} sets the alignment", () => {
  assert.deepStrictEqual(markup("{\\an8}top"), { spans: [{ text: "top" }], align: 8 });
  assert.deepStrictEqual(markup("{\\an1}<i>l</i>"), { spans: [{ text: "l", i: true }], align: 1 });
  assert.deepStrictEqual(markup("{\\pos(10,20)\\an9}x{\\an5}y"), { spans: [{ text: "xy" }], align: 9 });
  assert.deepStrictEqual(markup("{\\i1}x"), { spans: [{ text: "x" }], align: 2 });
  assert.deepStrictEqual(markup("{\\an0}x"), { spans: [{ text: "x" }], align: 2 });
  assert.deepStrictEqual(markup("{not an override}"), { spans: [{ text: "{not an override}" }], align: 2 });
});

// --- overlay.html against a minimal DOM -------------------------------------

function makeElement(tag) {
  const el = {
    tagName: tag,
    children: [],
    style: {},
    className: "",
    replaceChildren: (...nodes) => (el.children = nodes),
    appendChild: (n) => el.children.push(n),
    get textContent() {
      return el.children.map((c) => c.textContent).join("");
    },
    set innerHTML(v) {
      throw new Error("innerHTML used");
    },
  };
  return el;
}

function loadOverlay() {
  const html = fs.readFileSync(path.join(__dirname, "../../iina/overlay.html"), "utf8");
  const script = /<script>([\s\S]*?)<\/script>/.exec(html)[1];
  const cap = makeElement("div");
  const posted = [];
  const rendered = [];
  const window = {};
  const ctx = {
    window,
    iina: {
      postMessage: (name, data) => {
        posted.push([name, decodeURIComponent(data.t)]);
        rendered.push(decodeURIComponent(data.r));
      },
    },
    document: {
      getElementById: () => cap,
      createElement: makeElement,
      createTextNode: (text) => ({ textContent: text }),
    },
  };
  vm.runInNewContext(script, ctx);
  const show = (text) => window.setCue({ t: encodeURIComponent(text), m: encodeURIComponent(JSON.stringify(markup(text))) });
  return { cap, posted, rendered, show, setCue: window.setCue };
}

test("overlay renders spans, positions, and echoes the source text", () => {
  const o = loadOverlay();
  o.show("{\\an7}<b>bold</b> <font color=red>red</font>\nplain");
  assert.strictEqual(o.cap.textContent, "bold red\nplain");
  assert.strictEqual(o.cap.className, "top left");
  assert.strictEqual(o.cap.style.display, "block");
  assert.strictEqual(o.cap.children[0].style.fontWeight, "800");
  assert.strictEqual(o.cap.children[2].style.color, "red");
  assert.deepStrictEqual(o.posted.at(-1), ["shown", "{\\an7}<b>bold</b> <font color=red>red</font>\nplain"]);
  assert.strictEqual(o.rendered.at(-1), "bold red\nplain");

  o.show("a < b");
  assert.strictEqual(o.cap.className, "bottom center");
  assert.deepStrictEqual(o.posted.at(-1), ["shown", "a < b"]);

  o.show("");
  assert.strictEqual(o.cap.style.display, "none");
  assert.deepStrictEqual(o.posted.at(-1), ["shown", ""]);
});

test("overlay falls back to plain text without markup", () => {
  const o = loadOverlay();
  o.setCue({ t: encodeURIComponent("<i>x</i>") });
  assert.strictEqual(o.cap.textContent, "<i>x</i>");
  assert.deepStrictEqual(o.posted.at(-1), ["shown", "<i>x</i>"]);
});
