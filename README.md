# cueline

A transcript editor split across two plugins that talk to each other:

- **`nvim/`** — a Neovim plugin. Open an `.srt`, and the cue that is playing is
  highlighted (and followed) as the media plays. Seek, pause, nudge and retime
  cues from the buffer.
- **`iina/`** — an IINA plugin. Runs a local WebSocket server, reports playback
  to Neovim, and draws the cue text as a caption over the video — including
  your unsaved edits, so fixing a line in Neovim fixes it on screen immediately.

No build step and no runtime dependencies on either side.

## Install

### IINA plugin (dev mode)

Needs an IINA whose plugin API has the `ws` module; developed and tested against 1.5.0-beta2.

```nu
/Applications/IINA.app/Contents/MacOS/iina-plugin link ~/git/cueline/iina
# the link is named after the folder; renaming it is optional
let plugins = $"($env.HOME)/Library/Application Support/com.colliderli.iina/plugins"
mv $"($plugins)/iina.iinaplugin-dev" $"($plugins)/cueline.iinaplugin-dev"
defaults write com.colliderli.iina PluginEnabled.net.bajortski.cueline -bool true
```

Then quit and reopen IINA (plugins load at launch). It can also be enabled in
IINA > Settings > Plugins, where the WebSocket port can be changed (default
`10427`).

### Neovim plugin (lazy.nvim)

```lua
{
  dir = "~/git/cueline/nvim",
  name = "cueline",
  ft = "srt",
  cmd = { "CuelineConnect", "CuelineOpen" },
  opts = {
    -- auto_connect = true,
  },
}
```

Requires Neovim 0.10+. `:checkhealth cueline` checks the setup.

## Usage

1. Open the transcript: `nvim ~/Movies/harmontown-dnd/transcripts/part-01.srt`
2. `:CuelineOpen` opens the matching media in IINA (looks for the same name next
   to the SRT and in `../audio`, `../video`, `../media`), and connects. Or open
   the media in IINA yourself and run `:CuelineConnect`.
3. Play. The current cue is highlighted and the cursor follows it (pausing
   following for a moment whenever you move or type). Edit freely — the caption
   in IINA updates as you type.
4. While paused, moving the cursor previews the cue under it in the player.

Audio-only files: IINA opens them in *music mode* by default, which hides the
video area the caption is drawn on (cueline warns you when this happens). Leave
music mode (Video > Exit Music Mode), or untick IINA > Settings > General >
"Switch to "music mode" automatically when playing an audio file". Highlighting
and control work either way.

### Commands

| Command | Does |
| --- | --- |
| `:CuelineConnect [port]` | Connect (and keep reconnecting) to IINA |
| `:CuelineDisconnect` | Disconnect, stop reconnecting |
| `:CuelineOpen [path]` | Open the transcript's media (or `path`) in IINA and connect |
| `:CuelineSeek` | Seek the player to the start of the cue under the cursor |
| `:CuelineReplay` | Same, and play |
| `:CuelinePause` | Toggle play/pause |
| `:CuelineNudge [secs]` | Seek relative, default `nudge` (negative for back) |
| `:CuelineSpeed {x}` | Playback speed |
| `:CuelineFollow [on\|off]` | Toggle cursor following |
| `:CuelineAdjust {start\|end} {±secs}` | Shift the cue's start or end |
| `:CuelineStamp {start\|end}` | Set the cue's start or end to the player position |
| `:CuelineAttach` / `:CuelineDetach` | Manually (de)activate on a buffer |
| `:CuelineStatus` | Connection and player state |

### Default keymaps (buffer-local, normal mode)

| Key | Action |
| --- | --- |
| `<CR>` | seek to cue under cursor |
| `<localleader>r` | play from cue start |
| `<localleader>p` | play/pause |
| `<localleader>f` | toggle follow |
| `<localleader>h` / `<localleader>l` | nudge back / forward |
| `<localleader>[` / `<localleader>]` | cue start earlier / later |
| `<localleader>{` / `<localleader>}` | cue end earlier / later |
| `<localleader>S` / `<localleader>E` | stamp start / end from player time |

Override any of them in `opts.keymaps` (`false` disables one); `keymaps = false`
disables all.

### Options

```lua
{
  host = "127.0.0.1",
  port = 10427,
  reconnect = true,        -- keep retrying while connected is wanted
  auto_attach = true,      -- activate on filetype=srt
  auto_connect = false,    -- connect when the first SRT opens
  follow = true,           -- cursor follows playback
  follow_idle_ms = 2500,   -- ...but not this soon after your own moves/edits
  follow_center = true,    -- keep the playing cue centred (false: scroll only at the edge)
  preview_on_cursor = true,-- while paused, preview the cue under the cursor
  hide_subs = true,        -- hide IINA's own subtitle track while previewing
  lookahead = 3,           -- cues sent ahead so the caption switches on time
  nudge = 2,               -- seconds, nudge keys
  adjust = 0.1,            -- seconds, retiming keys
  seek_on_adjust = true,   -- after moving a start, seek there
  media_exts = { "m4a", "mp3", "wav", "flac", ... },
  media_dirs = { ".", "../audio", "../video", "../media" },
  keymaps = { ... },       -- see above
}
```

Highlight groups: `CuelineActive` (the playing cue, default link `DiffChange`)
and `CuelineSign` (the `▶` sign, default link `DiagnosticInfo`).
`require("cueline").statusline()` returns a short `▶ 01:02:03` string.

## How it works

- The IINA plugin's **global entry** owns the WebSocket server (one per IINA
  process, so multiple windows don't fight over the port) and routes messages.
  Each **player window** runs the main entry: it watches mpv's `time-pos`,
  pause state and file, executes commands, and renders captions in an overlay
  web view. The "active" player is the one that most recently loaded a file or
  started playing.
- Neovim has no WebSocket client, so `nvim/lua/cueline/ws.lua` is a small
  RFC 6455 client on `vim.uv` TCP (handshake, masked frames, fragmentation,
  ping/pong, close).
- SRT cues are indexed once and looked up by binary search. Text edits inside a
  cue are patched in place from `nvim_buf_attach` line events; structural edits
  (adding/removing lines, touching timestamps) trigger a lazy full reparse.
  On a 5000-cue file: parse ~15 ms, per-tick refresh ~0.03 ms, text edit
  ~0.01 ms, structural edit ~13 ms.
- mpv only updates `time-pos` every few hundred ms for audio-only files, so
  both sides extrapolate from the last report, and the player schedules a
  re-render exactly at the next cue boundary.

## Protocol

One WebSocket connection, `ws://127.0.0.1:10427/`, JSON text in each message
(IINA sends them as binary frames holding UTF-8). Every message has a `type`.
Times are seconds (floats).

**Neovim → IINA**

| type | fields | meaning |
| --- | --- | --- |
| `hello` | `client`, `version` | handshake; server replies with `hello` |
| `config` | `hide_subs` | preferences for the player |
| `seek` | `pos`, `play?` | absolute, exact seek (optionally resume) |
| `nudge` | `delta` | relative seek |
| `toggle-pause` / `pause` / `play` | | playback control |
| `speed` | `speed` | playback speed |
| `cues` | `items: [{id, start, end, text}]` | playing cue + lookahead; the player shows whichever contains the position |
| `cue` | `id, start, end, text, sticky` | preview one cue regardless of position (paused cursor preview) |
| `clear` | | remove the caption, restore IINA's subtitles |
| `open` | `path` | open a file in the active player |
| `ping` | `id?` | server replies `pong` |

**IINA → Neovim**

| type | fields | meaning |
| --- | --- | --- |
| `hello` | `server`, `version`, `player: {file, pos, paused, speed, duration} \| null` | reply to `hello` |
| `time` | `pos`, `paused`, `speed` | position, throttled to ≤10 Hz, on change only |
| `state` | `pos`, `paused`, `speed` | pause/resume, sent immediately |
| `file` | `file`, `duration`, `pos`, `paused`, `speed` | media loaded or active window changed |
| `shown` | `text`, `subs_hidden` | the overlay's DOM now shows `text` (acknowledgement) |
| `notice` | `message` | something the user should know (e.g. music mode hides the caption) |
| `error` | `message` | bad message, or no player window open |
| `pong` | `id` | |

Any WebSocket client can drive it, e.g. send `{"type":"seek","pos":90}`.

## Limitations

- IINA's `ws` module has no bind address: the server listens on all
  interfaces. The plugin ignores messages from non-loopback peers, but the port
  is reachable on your network. No TLS.
- The caption lives on the video view, so it isn't visible in music mode or
  picture-in-picture.
- Pausing an audio-only file within ~150 ms of a seek can leave mpv's reported
  position creeping forward for a moment; it settles.
- Only one IINA process can own the port. The e2e test launches its own IINA,
  so quit any IINA that already has cueline loaded first.

## Development

```nu
# Neovim unit + protocol tests (mock server), headless
nvim --headless --clean -l nvim/tests/run.lua
# IINA plugin logic against a fake `iina` API
node --test test/js/*.test.js
# end to end against the real IINA (launches and kills its own instance)
test/e2e/run.sh mp4
test/e2e/run.sh m4a

# lint, including cyclomatic complexity <= 10
nix run nixpkgs#luajitPackages.luacheck -- nvim test/e2e
npm install --cache /tmp/npm-cache  # ~/.npm needs a writable cache
npx eslint iina test/js
```

`test/make-fixtures.sh` regenerates the 60 s audio/video fixtures (ffmpeg).
IINA logs from the e2e run go to `$TMPDIR/cueline-e2e/`.

## License

MIT © Bajortski
