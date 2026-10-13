---
created: 2026-10-13T01:15
updated: 2026-10-13T01:31
---
# ASS cheatsheet

Quick reference for writing `.ass` by hand in cueline. Everything here renders
in the IINA preview (libass). The **YT** column says what survives
`:CuelineExport` to YouTube `.ytt` (via YTSubConverter):

- **yes**: converts as-is
- **part**: converts with limits (see note)
- **no**: dropped silently; the line still exports, just without the effect

Sources: [Aegisub ASS tag docs](https://aegisub.org/docs/latest/ass_tags/),
[YTSubConverter README](https://github.com/arcusmaximus/YTSubConverter) and its
source (v1.6.5).

## Minimal file

```ass
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Roboto,64,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,50,1
Style: Sign,Roboto,48,&H0000FFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,0,8,40,40,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.50,0:00:04.50,Default,Host,0,0,0,,Welcome back\Nto the show
Comment: 0,0:00:06.00,0:00:07.00,Default,,0,0,0,,timing note: check this one
Dialogue: 1,0:00:05.00,0:00:15.00,Sign,,0,0,0,,{\pos(960,80)}THE TAVERN
```

The `Format:` lines name the field order. Keep them exactly as above; every
`Style:`/`Dialogue:` line must match.

## [Script Info]

| Key | What | Notes |
|-------------------|-------------------------|-------|
| `PlayResX`/`PlayResY` | Script coordinate space | Every `\pos`, `\move`, `\clip`, margin and `\fs` is in these units, scaled to the video. Match the video's aspect (1920x1080 for 16:9). Missing = 384x288, which squashes things on 16:9. YouTube maps `\pos` as a fraction of this too. |
| `WrapStyle` | Default line wrapping | `0` smart, top line wider; `1` greedy end-of-line; `2` no wrap (only `\N` breaks, `\n` too); `3` smart, bottom line wider. Same values as `\q`. |
| `ScaledBorderAndShadow` | Border/shadow units | `yes`: script pixels, scale with PlayRes (what you want). `no`: video pixels, so borders look thinner on a 4K video than a 720p one. |
| `ScriptType` | Format version | `v4.00+` for ASS. |

## [V4+ Styles] fields

Bool fields use `-1` = on, `0` = off.

| Field | What | YT |
|---|---|---|
| `Name` | Style name; referenced by events and `\r` | yes. `Default` (or the first style) is the 100% size baseline; `YTGlow` etc. pick a shadow type, see [YouTube shadows](#youtube-shadows-and-style-options) |
| `Fontname` | Font family | part: only Carrois Gothic SC, Comic Sans MS, Courier New, Lucida Console, Monotype Corsiva, Roboto, Times New Roman; anything else becomes Roboto |
| `Fontsize` | Height in script px | part: relative to `Default` (Default 48, Sign 96 = 200%); floor 75%; Android ignores it |
| `PrimaryColour` | Fill colour | yes |
| `SecondaryColour` | Karaoke unsung fill | yes |
| `OutlineColour` | Border colour (box colour when `BorderStyle` 3) | yes (glow colour, or background box colour) |
| `BackColour` | Shadow colour | yes (shadow colour) |
| `Bold` | `-1`/`0` | yes |
| `Italic` | `-1`/`0` | yes |
| `Underline` | `-1`/`0` | yes |
| `StrikeOut` | `-1`/`0` | no |
| `ScaleX`/`ScaleY` | Glyph stretch, % | no |
| `Spacing` | Extra letter spacing, px | no |
| `Angle` | Z rotation, degrees | no |
| `BorderStyle` | `1` outline + shadow; `3` opaque box behind text | part: `3` with `Outline` > 0 becomes YouTube's background box (in `OutlineColour`). Mobile always draws a black box. |
| `Outline` | Border width, px | part: only 0 vs >0 |
| `Shadow` | Shadow offset, px | part: only 0 vs >0 |
| `Alignment` | Numpad position, 1-9 | yes |
| `MarginL`/`MarginR`/`MarginV` | Edge margins, px | no |
| `Encoding` | Charset; `1` = default | no (irrelevant) |

## [Events] fields

`Dialogue:` renders, `Comment:` doesn't (handy for notes).

| Field | What | YT |
|---|---|---|
| `Layer` | Higher draws on top. Lines on different layers don't push each other out of the way | no (ignored) |
| `Start`/`End` | `h:mm:ss.cc` (centiseconds) | yes |
| `Style` | Style name | yes |
| `Name` | Actor/speaker label, never rendered | n/a |
| `MarginL`/`R`/`V` | Per-line margin override; `0` = use style | no |
| `Effect` | Legacy `Banner;`/`Scroll up;` effects; usually empty | no. YTSubConverter reads `no_android_dark_text_hack` here (see caveats) |
| `Text` | Text plus `{\override}` blocks | see tags |

**Trimming fields.** You can drop fields you don't use from the `Format:` line
(e.g. `Format: Layer, Start, End, Style, Name, Text`) and from every
`Dialogue:` line to match. mpv/IINA then ignore each line's `Style`, and
YTSubConverter refuses the file, so only do this if you preview and export
through cueline, which expands the copy it hands to both. Leave `[V4+ Styles]`
untrimmed.

## Colours

Format is `&HAABBGGRR` in styles, `&HBBGGRR&` in `\c` tags, alpha separately as
`&HAA&`. **Blue-green-red, backwards from HTML.** **Alpha `00` is opaque, `FF`
is invisible**, the opposite of what you'd guess.

| Want               | Style field  | Override               |
| ------------------ | ------------ | ---------------------- |
| White              | `&H00FFFFFF` | `\c&HFFFFFF&`          |
| Black              | `&H00000000` | `\c&H000000&`          |
| Red (`#FF0000`)    | `&H000000FF` | `\c&H0000FF&`          |
| Blue (`#0000FF`)   | `&H00FF0000` | `\c&HFF0000&`          |
| Yellow (`#FFFF00`) | `&H0000FFFF` | `\c&H00FFFF&`          |
| Pink (`#FF66CC`)   | `&H00CC66FF` | `\c&HCC66FF&`          |
| 50% black shadow   | `&H80000000` | `\4c&H000000&\4a&H80&` |
| Invisible          | `&HFF......` | `\alpha&HFF&`          |

HTML `#RRGGBB` to ASS: swap first and last pairs, `RRGGBB` -> `BBGGRR`.

## Alignment (`\an`, style `Alignment`)

```
 7 ---- 8 ---- 9     top
 |             |
 4      5      6     middle
 |             |
 1 ---- 2 ---- 3     bottom (2 = default)
left  centre  right
```

With `\pos`, the number picks which point of the text box sits at `(x,y)`:
`{\an8\pos(960,40)}` puts the top-centre of the text at 960,40.

On YouTube, alignment also decides how the caption dodges the player controls
on hover: 7-9 move down, 4-6 stay, 1-3 move up.

## Override tags

Write tags in `{}` at the point they take effect. Tags marked *line* apply to the
whole line, wherever they are; use each once (YTSubConverter keeps the first).
Times in `\t`, `\move`, `\fad`, `\fade` are ms from the line start; `\k` is
centiseconds.

### Text

| Tag | Does | Example | YT |
|---|---|---|---|
| `\b` | Bold `1`/`0`, or weight `100`-`900` | `{\b1}loud{\b0}` | yes (on/off only) |
| `\i` | Italic | `{\i1}word{\i0}` | yes |
| `\u` | Underline | `{\u1}word{\u0}` | yes |
| `\s` | Strikeout | `{\s1}word{\s0}` | no |
| `\fn` | Font name, no space or quotes | `{\fnComic Sans MS}` | part: allowed fonts only |
| `\fs` | Font size, script px | `{\fs96}BIG` | part: relative to `Default`, min 75%, Android ignores |
| `\fscx`/`\fscy` | Stretch, % | `{\fscx150}` | no |
| `\fsp` | Letter spacing, px (negative ok) | `{\fsp10}S P A C E` | no |
| `\q` | Wrap style for this line, 0-3 | `{\q2}` | no |

### Colour and alpha

| Tag | Does | Example | YT |
|---|---|---|---|
| `\c` / `\1c` | Fill colour | `{\c&H00FFFF&}` | yes |
| `\2c` | Karaoke unsung colour | `{\2c&H808080&}` | yes |
| `\3c` | Border colour | `{\3c&H000000&}` | yes (glow or box colour) |
| `\4c` | Shadow colour | `{\4c&H000000&}` | yes |
| `\alpha` | All four alphas | `{\alpha&H80&}` | yes |
| `\1a` | Fill alpha | `{\1a&HFF&}` | yes |
| `\2a` | Unsung alpha | `{\2a&HFF&}` | yes: `FF` switches on YouTube's native karaoke (hides unsung text, works on mobile) |
| `\3a` | Border alpha | `{\3a&H80&}` | yes (background box transparency) |
| `\4a` | Shadow alpha | `{\4a&H80&}` | part: only with `\4c&H222222&` and equal to the fill alpha |

### Border, shadow, blur

| Tag | Does | Example | YT |
|---|---|---|---|
| `\bord` | Border width (0 = off) | `{\bord4}` | no (style on/off only) |
| `\xbord`/`\ybord` | Border width per axis | `{\xbord6\ybord2}` | no |
| `\shad` | Shadow distance (0 = off) | `{\shad3}` | no (style on/off only) |
| `\xshad`/`\yshad` | Shadow offset per axis, negative ok | `{\xshad-3\yshad3}` | no |
| `\be` | Edge soften, integer passes | `{\be1}` | no |
| `\blur` | Gaussian edge blur (preferred over `\be`) | `{\blur2}` | no |

### Position and transform

| Tag | Does | Example | YT |
|---|---|---|---|
| `\an` | Alignment 1-9 (*line*) | `{\an8}` | yes |
| `\pos(x,y)` | Absolute position (*line*) | `{\pos(960,80)}` | yes; off-centre lines drift outward in theater mode |
| `\move(x1,y1,x2,y2[,t1,t2])` | Linear move, optional time window (*line*) | `{\move(100,540,1820,540,0,2000)}` | yes |
| `\org(x,y)` | Rotation pivot (*line*, first wins) | `{\org(960,540)\frz30}` | no |
| `\frz` / `\fr` | Rotate in-plane, degrees | `{\frz-10}` | no |
| `\frx`/`\fry` | 3D tilt around X/Y | `{\fry45}` | no |
| `\fax`/`\fay` | Shear factor, ~-2..2 | `{\fax-0.3}` | no |
| `\clip(x1,y1,x2,y2)` | Show only inside rect (*line*) | `{\clip(0,0,960,1080)}` | no |
| `\iclip(...)` | Hide inside rect (*line*) | `{\iclip(0,0,960,1080)}` | no |
| `\clip([scale,]drawing)` | Vector mask, `\p` syntax | `{\clip(m 0 0 l 500 0 500 500)}` | no |

### Time

| Tag | Does | Example | YT |
|---|---|---|---|
| `\fad(in,out)` | Fade in/out, ms (*line*) | `{\fad(200,300)}` | yes; outline/shadow only fade along if their colour is `&H222222&` |
| `\fade(a1,a2,a3,t1,t2,t3,t4)` | Alpha `a1` until `t1`, to `a2` by `t2`, hold until `t3`, to `a3` by `t4`. Alphas decimal 0-255, 255 = invisible (*line*) | `{\fade(255,0,255,0,300,1700,2000)}` | yes; same `&H222222&` caveat |
| `\t([t1,t2,][accel,]tags)` | Animate tags; `accel` 1 linear, <1 starts fast, >1 starts slow | `{\t(0,500,\fs96\c&H0000FF&)}` | part: only `\c \1c-\4c \alpha \1a-\4a \fs` animate |
| `\k<cs>` | Karaoke syllable, instant highlight | `{\k50}la` | yes |
| `\kf<cs>` / `\K<cs>` | Karaoke sweep, left to right | `{\kf50}la` | no: ignored and the syllable split is lost; use `\k` |
| `\ko<cs>` | Karaoke, outline appears on highlight | `{\ko50}la` | no: ignored; use `\k` |

### Other

| Tag | Does | Example | YT |
|---|---|---|---|
| `\r` / `\r<Style>` | Reset to line style, or switch to another style; also cancels running `\t` | `{\c&H0000FF&}red{\r} normal` | yes |
| `\p<n>` | Drawing mode; scale is 2^(n-1). Commands `m` move, `n` move w/o close, `l` line, `b` cubic bezier, `s`/`p`/`c` spline | `{\p1}m 0 0 l 100 0 100 100 l 0 100{\p0}` | no |
| `\pbo<n>` | Drawing baseline offset | `{\pbo-50}` | no |

### Escapes (no braces)

| Seq | Does | YT |
|---|---|---|
| `\N` | Hard line break, always | yes |
| `\n` | Soft break: only breaks with `WrapStyle`/`\q` 2, otherwise a space | becomes a non-breaking space, never a break |
| `\h` | Non-breaking space | yes |

## YouTube-only tags

libass ignores these, so the preview won't show them. Most are PC-only.

| Tag | Does | Syntax |
|---|---|---|
| `\ytsub` | Subscript from here (PC) | `H{\ytsub}2{\ytsur}O` |
| `\ytsup` | Superscript from here (PC) | `x{\ytsup}2{\ytsur}` |
| `\ytsur` | Back to regular script | |
| `\ytruby` | Ruby text for `[base/ruby]` pairs; `8` above (default), `2` below. Mobile shows `base(ruby)` | `{\ytruby}これは[漢/かん][字/じ]です` |
| `\ytvert` | Vertical text (PC). `9` columns right-to-left, `7` columns left-to-right, `1` whole sub rotated 90° CCW, `3` rotated with line order reversed | `{\ytvert9}` |
| `\ytdir4` | Mark line right-to-left (RTL text inside LTR-language subs). `\ytdir6` (LTR in RTL subs) is broken on YouTube's side | `{\ytdir4}` |
| `\ytpack` | `1` start / `0` stop packing text into one full-width character cell (PC, vertical text only) | `{\ytpack1}12{\ytpack0}` |
| `\ytshake` | Random jitter. Default 20px for the whole line | `{\ytshake}`, `(r)`, `(rx,ry)`, `(r,t1,t2)`, `(rx,ry,t1,t2)` |
| `\ytchroma` | RGB copies converge at start, split at end. Default 20px over 270ms | `{\ytchroma}`, `(in,out)`, `(x,y,in,out)`, `(&Hc1&,&Hc2&,...,&Ha&,x,y,in,out)` |
| `\ytkt` | Karaoke types: `Fade` (big files, can lag), `Glitch` (random chars; best left-aligned with invisible unsung), `Cursor`/`LCursor` (text after/before the current word, optionally styled or animated) | `{\ytktFade}`, `{\ytkt(Cursor,▼)}`, `{\ytkt(Cursor,tags,text)}`, `{\ytkt(Cursor,interval,tags1,text1,tags2,text2)}` |

## YouTube shadows and style options

YouTube has four shadow types: **glow** (an outline), **bevel**, **soft
shadow** and **hard shadow**, combinable. Defaults by style:

- `Outline` > 0, `BorderStyle` 1: glow in `OutlineColour`
- `Outline` > 0, `BorderStyle` 3: background box in `OutlineColour` (`\3a` = box alpha)
- `Shadow` > 0: soft shadow in `BackColour`

To pick a type without the GUI, give the style one of these built-in names.
The type only applies when the style's `Shadow` > 0; the `Box` variants are the
same types, meant for `BorderStyle` 3 styles:

`YTPlain` `YTPlainBox` `YTGlow` `YTGlowBox` `YTSoftShadow` `YTSoftShadowBox`
`YTHardShadow` `YTHardShadowBox` `YTBevel` `YTBevelBox`

Anything finer (several types on one style, or karaoke "highlight current word"
with its own text/outline/shadow colours) is set per style name in the
YTSubConverter GUI's *Style options*. The GUI saves it to `StyleOptions.xml`
beside its executable, and the command-line converter that `:CuelineExport` runs
reads the same file, so set it once in the GUI and it sticks for that style
name.

## YouTube caveats

- Mobile apps ignore background colour/alpha; they always draw a black box. Dark
  text that reads fine on a light box on PC is unreadable on mobile.
  YTSubConverter adds an invisible bright copy that Android shows (iOS
  doesn't). Put `no_android_dark_text_hack` in a line's `Effect` field to turn
  that off.
- Android ignores font size.
- Off-centre `\pos` lines drift toward the edges in PC theater mode, sometimes
  off the frame.
- `\4a` only works with shadow colour `&H222222&` and alpha equal to the fill's.
- `\fad`/`\fade` don't fade outlines or shadows unless their colour is
  `&H222222&`.
- Heavy use of `\t`, fades or `\move` can make mobile hide the track entirely.
- YouTube Studio's preview shows no styling; check in the real player after
  publishing. Editing the track in Studio wipes the styling.

## Recipes

| Recipe | Text | YT |
|---|---|---|
| Karaoke line | `{\k40}Twin{\k40}kle {\k45}twin{\k40}kle` (unsung uses `SecondaryColour`) | yes |
| Karaoke, unsung hidden | `{\2a&HFF&\k40}Twin{\k40}kle` | yes (native karaoke, works on mobile) |
| Top-of-screen sign | `{\an8}THE TAVERN`, or `{\an8\pos(960,40)}` for an exact spot | yes (`\pos` off-centre drifts in theater mode) |
| Coloured speaker name | `{\c&H00FFFF&\b1}HOST:{\r} Welcome back` | yes |
| Fade in/out | `{\fad(250,250)}Text` | yes (outline/shadow stay unless `&H222222&`) |
| Typewriter | `{\2a&HFF&\k8}T{\k8}y{\k8}p{\k8}e{\k8}d` (each letter appears on its beat) | yes |
| Two speakers at once, one line | `{\c&HFFCC66&}- You first.\N{\c&H66CCFF&}- No, you.` | yes |
| Two speakers at once, split | Two `Dialogue` lines, same times: `{\an1}Left guy` and `{\an3}Right guy` | yes |
| Colour pulse | `{\t(0,300,\c&H0000FF&)\t(300,600,\c&HFFFFFF&)}Alert` | yes (colour `\t` is supported) |
| Slide in | `{\move(-200,1000,960,1000,0,400)}Here` | yes |

## Gotchas

- **`\N` vs `\n`**: `\N` always breaks. `\n` is a space unless wrap style is
  2, and on YouTube it's a non-breaking space. Use `\N`.
- **Braces vanish**: everything inside `{}` is treated as tags; unknown text is
  silently dropped, so `{note to self}` works as an inline comment. There's no
  portable way to show a literal `{`.
- **Overrides stick** until the end of the line or a matching off-tag. `{\r}`
  drops all of them back to the line's style; `{\rSign}` switches style
  mid-line.
- **Line-level tags** (`\pos \move \an \org \clip \iclip \fad \fade`): one of
  each per line, at the start. Duplicates are renderer-dependent;
  YTSubConverter keeps the first. Don't mix `\pos` with `\move`, or `\fad` with
  `\fade`.
- **Layers**: higher `Layer` draws on top; lines on the same layer that
  overlap in time get stacked so they don't collide, different layers overlap
  freely. Put signs on layer 1 so they don't shove dialogue around.
- **PlayRes scaling**: coordinates and sizes are in PlayRes units. Changing
  `PlayResX/Y` without rescaling moves and resizes everything. Keep it
  1920x1080 and `ScaledBorderAndShadow: yes`.
- **Colours are BGR**, alpha `00` = opaque. If red came out blue, you typed HTML
  order.
- **`\fade` alphas are decimal** (0-255); every other alpha is hex `&HAA&`.
- **`\k` is centiseconds**; `\t`, `\move`, `\fad` are milliseconds.
