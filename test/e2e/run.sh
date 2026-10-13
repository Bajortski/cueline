#!/usr/bin/env bash
# End-to-end test against the real IINA app. Starts its own IINA process on a
# fixture, runs the headless Neovim client against it, and kills only that
# PID afterwards. Nothing is screen-captured; verification is via the
# protocol and IINA's log output.
#
#   test/e2e/run.sh [mp4|m4a|ass]
#
# `ass` plays the mp4 with sample.ass in Neovim, which IINA renders with
# libass from a temp file.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
kind="${1:-mp4}"
fixtures="$repo/test/fixtures"
script="$here/e2e.lua"
subs="$fixtures/sample.srt"
media_kind="$kind"
extra=()
if [ "$kind" = ass ]; then
  script="$here/e2e_ass.lua"
  subs="$fixtures/sample.ass"
  media_kind=mp4
  # a subtitle track of the user's own, which must be selected again after
  # cueline's track is dropped
  extra=(--mpv-sub-files="$fixtures/sample.srt")
fi
media="$fixtures/sample.$media_kind"
logdir="${TMPDIR:-/tmp}/cueline-e2e"
mkdir -p "$logdir"
log="$logdir/iina-$kind.log"

[ -f "$media" ] || "$repo/test/make-fixtures.sh"

port="${CUELINE_PORT:-10427}"
if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $port is already in use (an IINA with cueline loaded?); quit it first." >&2
  exit 2
fi
# An IINA you already have open is left alone: this launches a separate
# process and only ever kills that PID.

# -key value pairs land in NSUserDefaults' argument domain for this process
# only: enable logging to stdout and keep the fixture out of history/resume.
NSUnbufferedIO=YES /Applications/IINA.app/Contents/MacOS/IINA \
  -enableAdvancedSettings YES -enableLogging YES \
  -recordPlaybackHistory NO -recordRecentFiles NO -resumeLastPosition NO \
  -autoSwitchToMusicMode NO -pauseWhenOpen NO \
  --mpv-resume-playback=no --mpv-save-position-on-quit=no --mpv-volume=0 \
  ${extra[@]+"${extra[@]}"} "$media" >"$log" 2>&1 &
iina_pid=$!
trap 'kill "$iina_pid" 2>/dev/null || true; wait "$iina_pid" 2>/dev/null || true' EXIT
echo "IINA pid $iina_pid, log $log"

status=0
nvim --headless --clean -l "$script" "$subs" "sample.$media_kind" || status=$?

echo "--- cueline lines from IINA log ---"
grep -i "cueline\|ws-server\|net.bajortski" "$log" | grep -v "^\s*$" | tail -25 || true
exit $status
