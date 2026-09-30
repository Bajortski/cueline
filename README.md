# cueline

Edit subtitle and transcript files in Neovim while the media plays in
[IINA](https://iina.io).

cueline is two small plugins that talk to each other:

- a **Neovim plugin** that highlights the line being spoken right now and keeps
  it in view as playback moves along, and
- an **IINA plugin** that shows that line as a caption over the video, including
  any changes you've typed but not yet saved.

Fix a typo in Neovim and it's corrected on screen as you type. Put the cursor on
a line and press Enter to hear it. Nudge a line's start or end time without
leaving the keyboard.

It works with any `.srt` file: auto-generated transcripts (Whisper and the
like), subtitles you're translating, or captions you're timing by hand.

## Requirements

- macOS with **IINA 1.4 or newer** (tested on 1.5.0-beta2)
- **Neovim 0.10 or newer**

Neither plugin has any other dependencies.

## Installation

You need both halves.

### 1. The IINA plugin

In IINA, open **Settings → Plugins**, click **Install from GitHub…**, and enter:

```
Bajortski/cueline
```

Alternatively, download `cueline.iinaplgz` from the
[latest release](https://github.com/Bajortski/cueline/releases/latest) and
double-click it.

Make sure the plugin is enabled, then **quit and reopen IINA**. Plugins are only
loaded when IINA starts.

### 2. The Neovim plugin

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Bajortski/cueline",
  ft = "srt",
  cmd = { "CuelineConnect", "CuelineOpen" },
  opts = {},
}
```

With any other plugin manager, add `Bajortski/cueline` and call
`require("cueline").setup()`.

Run `:checkhealth cueline` to check that everything is in place.

## Getting started

1. Open a transcript in Neovim:

   ```
   nvim episode-01.srt
   ```

2. Run `:CuelineOpen`. cueline looks for media with the same name
   (`episode-01.m4a`, `episode-01.mp4`, …) next to the transcript, or in a
   sibling `audio/`, `video/` or `media/` folder. It opens the file in IINA and
   connects.

   If your media lives somewhere else, give the path yourself:
   `:CuelineOpen ~/Movies/episode-01.mp4`. Or open it in IINA however you like
   and run `:CuelineConnect`.

3. Press play. The line being spoken is highlighted, and the view scrolls to
   keep it centred.

4. Edit as you go. The caption in IINA updates with every keystroke. Save with
   `:w` as usual.

Whenever you move the cursor or type, following pauses for a couple of seconds
so it doesn't yank the cursor away mid-edit. While playback is paused, moving
the cursor previews the line under it in the player.

### A note on audio files

IINA opens audio-only files in **music mode**, which hides the video area the
caption is drawn on. Highlighting and all the controls still work, but to see
the caption either choose **Video → Exit Music Mode**, or turn off *Settings →
General → Switch to "music mode" automatically when playing an audio file*.
cueline tells you in Neovim when it detects this.

## Keys

These are set in `.srt` buffers only. All of them can be changed or turned off
(see [Configuration](#configuration)).

| Key | Action |
| --- | --- |
| `<CR>` | Jump the player to the line under the cursor |
| `<localleader>r` | Play the line under the cursor from its start |
| `<localleader>p` | Play / pause |
| `<localleader>f` | Turn following on or off |
| `<localleader>h` / `<localleader>l` | Skip back / forward 2 seconds |
| `<localleader>[` / `<localleader>]` | Move the line's start time earlier / later |
| `<localleader>{` / `<localleader>}` | Move the line's end time earlier / later |
| `<localleader>S` / `<localleader>E` | Set the line's start / end to the current playback position |

`<localleader>` is `\` unless you've set `maplocalleader`.

## Commands

| Command | Does |
| --- | --- |
| `:CuelineOpen [path]` | Open the transcript's media (or `path`) in IINA and connect |
| `:CuelineConnect [port]` | Connect to IINA, retrying until it's available |
| `:CuelineDisconnect` | Disconnect and stop retrying |
| `:CuelineSeek` | Jump the player to the line under the cursor |
| `:CuelineReplay` | Same, and start playing |
| `:CuelinePause` | Play / pause |
| `:CuelineNudge [secs]` | Skip by `secs` (negative goes back; default 2) |
| `:CuelineSpeed {x}` | Set playback speed, e.g. `:CuelineSpeed 1.5` |
| `:CuelineFollow [on\|off]` | Turn following on, off, or toggle it |
| `:CuelineAdjust {start\|end} {secs}` | Shift the line's start or end by `secs` |
| `:CuelineStamp {start\|end}` | Set the line's start or end to the playback position |
| `:CuelineAttach` / `:CuelineDetach` | Turn cueline on or off for the current buffer |
| `:CuelineStatus` | Show connection and player state |

Full documentation is in `:help cueline`.

## Configuration

Pass options to `setup()` (or `opts` in lazy.nvim). The defaults:

```lua
require("cueline").setup({
  port = 10427,             -- must match the port in IINA's plugin settings
  auto_attach = true,       -- turn on for every .srt buffer
  auto_connect = false,     -- connect as soon as an .srt is opened
  follow = true,            -- move the cursor along with playback
  follow_idle_ms = 2500,    -- ...but not this soon after you move or type
  follow_center = true,     -- keep the playing line centred (false: scroll only at the edge)
  preview_on_cursor = true, -- while paused, preview the line under the cursor
  hide_subs = true,         -- hide IINA's own subtitles while cueline's caption is showing
  nudge = 2,                -- seconds skipped by the nudge keys
  adjust = 0.1,             -- seconds moved by the timing keys
  seek_on_adjust = true,    -- after moving a start time, jump there so you can hear it
  media_dirs = { ".", "../audio", "../video", "../media" }, -- where :CuelineOpen looks
  keymaps = {
    seek = "<CR>",
    replay = "<localleader>r",
    toggle_pause = "<localleader>p",
    follow = "<localleader>f",
    back = "<localleader>h",
    forward = "<localleader>l",
    start_earlier = "<localleader>[",
    start_later = "<localleader>]",
    end_earlier = "<localleader>{",
    end_later = "<localleader>}",
    stamp_start = "<localleader>S",
    stamp_end = "<localleader>E",
  },
})
```

Set any key to `false` to disable it, or `keymaps = false` to disable them all.

The highlight uses the `CuelineActive` group (linked to `DiffChange` by default)
and the `▶` sign uses `CuelineSign`. Override either in your colour scheme.

For your statusline, `require("cueline").statusline()` returns the playback
position, e.g. `▶ 01:02:03` (`⏸` when paused).

To change the port, set it in both places: **IINA → Settings → Plugins →
cueline**, and `port` in the Neovim options.

## Troubleshooting

**`:CuelineConnect` keeps retrying.** IINA isn't running, or it was already
running when you installed the plugin. Quit and reopen IINA. Also check the
plugin is enabled in Settings → Plugins, and that both sides use the same port.

**The highlight works but there's no caption in IINA.** You're probably in music
mode; see [A note on audio files](#a-note-on-audio-files).

**`:CuelineOpen` can't find the media.** Pass the path:
`:CuelineOpen /path/to/file.mp4`, or add your folder layout to `media_dirs`.

**The cursor doesn't follow.** Following pauses for `follow_idle_ms` after you
move or type, and doesn't happen in insert mode. `<localleader>f` toggles it;
`:CuelineStatus` shows whether it's on.

`:checkhealth cueline` covers most setup problems.

## Security

IINA's plugin API can't restrict its WebSocket server to your own machine, so
the port (10427) is open on your local network while IINA is running. The
plugin ignores anything that doesn't come from your own machine, and it can
only control playback, but if you're on an untrusted network you may want your
firewall to block the port.

## Known limitations

- The caption is drawn on the video, so it isn't visible in music mode or
  picture-in-picture.
- Only one IINA window is controlled at a time: whichever most recently opened
  a file or started playing.
- Only `.srt` files are supported.

## How it works

The IINA plugin runs a small WebSocket server and reports the playback position
about ten times a second. Neovim connects to it, works out which line is
playing, and sends that line (and the next few) back to be drawn as a caption.
The full message format is in [docs/protocol.md](docs/protocol.md), if you want
to write your own client.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for running the tests and cutting a
release.
