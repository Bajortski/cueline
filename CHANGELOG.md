# Changelog

## Unreleased

- `.srt` captions render `<b>`, `<i>`, `<u>`, `<s>` and `<font color>` tags,
  and `{\anN}` positions them.
- `.ass`/`.ssa` support: parsing, highlighting (including overlapping lines),
  following and retiming in Neovim, and a live preview through IINA's own
  libass renderer, unsaved edits included.
- `.ass` files may trim unused event fields (margins, Effect) from their
  `Format:` line; cueline restores them for IINA and the export, and fixes
  Neovim's `ssa` syntax highlighting, which assumes all ten fields.
- Every command also works typed in lowercase (`:cuelineopen`).
- `:CuelineExport` converts a buffer to YouTube's styled `.ytt` format with
  YTSubConverter.
- The IINA plugin now asks for file-system access, to load the `.ass` preview
  track.
- The `shown` message also carries `rendered`, and IINA sends `track` updates
  (see docs/protocol.md).

## 0.1.0 (2026-09-30)

First release.

- Neovim plugin for `.srt` files: highlights the line playing in IINA and keeps
  it centred as playback moves.
- IINA plugin: shows the playing line as a caption over the video, updated live
  as you edit it in Neovim.
- `:CuelineOpen` finds the media next to the transcript, opens it in IINA and
  connects.
- Seek, play/pause, skip, speed, and retiming lines from the keyboard.
- Previews the line under the cursor while paused.
- `:checkhealth cueline`.
