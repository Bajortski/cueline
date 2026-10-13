# Contributing

## Layout

```
lua/cueline/     Neovim plugin
plugin/          Neovim commands and autocommands
doc/             :help cueline
iina/            IINA plugin (Info.json, src/, overlay.html, pref.html)
test/nvim/       Neovim tests, run headless against a mock server
test/js/         IINA plugin tests, run in node against a fake iina API
test/e2e/        End-to-end test against a real IINA
scripts/         Release packaging
docs/            Protocol reference
```

The Neovim plugin sits at the repo root so plugin managers can install it
directly from GitHub. The IINA plugin is shipped as a `.iinaplgz` release asset.

## Developing

Point your plugin manager at your checkout, e.g. with lazy.nvim:

```lua
{ dir = "~/src/cueline", name = "cueline", ft = { "srt", "ssa" }, opts = {} }
```

Link the IINA plugin in development mode, enable it, and restart IINA:

```sh
/Applications/IINA.app/Contents/MacOS/iina-plugin link iina
defaults write com.colliderli.iina PluginEnabled.net.bajortski.cueline -bool true
```

IINA only loads plugins at launch, so restart it after changing the IINA side.
Its log (Window → Log Viewer) shows the plugin's output.

## Tests

```sh
# Neovim: parser, WebSocket client, and protocol round trips against a mock server
nvim --headless --clean -l test/nvim/run.lua

# IINA plugin logic against a fake iina API
npm install
npm test

# End to end against the real IINA; launches and quits its own instance.
# Quit any IINA that has cueline loaded first, since only one can own the port.
test/make-fixtures.sh      # generates the audio/video fixtures (needs ffmpeg)
test/e2e/run.sh mp4
test/e2e/run.sh m4a
```

The end-to-end run writes IINA's logs to `$TMPDIR/cueline-e2e/`.

## Lint

Both halves keep cyclomatic complexity at 10 or below. Prefer a lookup table
over a growing `if`/`elseif` chain; message handling and commands already work
this way.

```sh
luacheck lua plugin test     # config in .luacheckrc
npm run lint                 # eslint, config in eslint.config.js
```

## Releasing

1. Bump the version in all three places:
   - `lua/cueline/init.lua` (`M.version`)
   - `iina/src/protocol.js` (`VERSION`)
   - `iina/Info.json` (`version`)
2. Add the release to `CHANGELOG.md`.
3. Run the tests and lint.
4. Build the IINA package: `scripts/pack-iina.sh` writes
   `dist/cueline.iinaplgz`.
5. Tag and push: `git tag v0.1.0 && git push origin main v0.1.0`.
6. Create a GitHub release for the tag and attach `dist/cueline.iinaplgz`.
   IINA's **Install from GitHub** installs the `.iinaplgz` from the latest
   release, so the asset must be attached for that to work.
