# cueline protocol

The IINA plugin runs a WebSocket server; the Neovim plugin is a client. Anything
that speaks WebSocket can use it: a script, another editor, a remote control.

- **Address:** `ws://127.0.0.1:10427/` (the port is set in IINA → Settings →
  Plugins → cueline)
- **Messages:** one JSON object per WebSocket message. IINA sends them as binary
  frames containing UTF-8 JSON; it accepts text or binary.
- Every message has a `type`. Times are seconds, as floats.
- Messages from anything other than the local machine are ignored.

## Client → IINA

| `type` | Fields | Meaning |
| --- | --- | --- |
| `hello` | `client`, `version` | Say hello; IINA replies with its own `hello` |
| `config` | `hide_subs` | Whether to hide IINA's own subtitles while a caption is showing |
| `seek` | `pos`, `play?` | Jump to `pos` exactly; start playing if `play` is true |
| `nudge` | `delta` | Jump by `delta` seconds from the current position |
| `toggle-pause`, `pause`, `play` | none | Playback control |
| `speed` | `speed` | Playback speed |
| `cues` | `items: [{id, start, end, text}]` | The playing line and the next few; the player shows whichever one contains the current position |
| `cue` | `id`, `start`, `end`, `text`, `sticky` | Show this one line regardless of position (used for previewing while paused) |
| `clear` | none | Remove the caption and restore IINA's subtitles |
| `open` | `path` | Open a file in the active player window |
| `ping` | `id?` | IINA replies with `pong` |

## IINA → client

| `type` | Fields | Meaning |
| --- | --- | --- |
| `hello` | `server`, `version`, `player` | Reply to `hello`. `player` is `{file, pos, paused, speed, duration}`, or `null` if no window is open |
| `time` | `pos`, `paused`, `speed` | Playback position; sent when it changes, at most 10 times a second |
| `state` | `pos`, `paused`, `speed` | Paused or resumed; sent immediately |
| `file` | `file`, `duration`, `pos`, `paused`, `speed` | A file was loaded, or a different window became active |
| `shown` | `text`, `subs_hidden` | The caption now on screen reads `text` |
| `notice` | `message` | Something worth telling the user, e.g. music mode is hiding the caption |
| `error` | `message` | A malformed message, or no player window is open |
| `pong` | `id` | Reply to `ping` |

## Example

With [websocat](https://github.com/vi/websocat):

```
$ websocat ws://127.0.0.1:10427/
{"type":"hello","client":"test","version":"0"}
{"type":"seek","pos":90,"play":true}
```

## Timing notes

- For audio-only files, mpv updates the position only every 100–500 ms. Clients
  should estimate the position between `time` messages from the last `pos` and
  `speed` while not `paused`. The Neovim plugin does this.
- Sending the next few lines in `cues` lets the player switch captions exactly
  on time, without waiting for a round trip to the client.

## Architecture

- The IINA plugin's **global entry** owns the server, so there is one per IINA
  process however many windows are open. It routes messages to the **active
  player**: whichever window most recently opened a file or started playing.
- Each **player window** runs the main entry. It watches mpv's `time-pos`, pause
  state and file, carries out commands, and draws the caption in an overlay.
- Neovim has no built-in WebSocket client, so `lua/cueline/ws.lua` implements a
  minimal one (RFC 6455) on top of `vim.uv`.
