#!/usr/bin/env bash
# Generate the 60 s audio/video fixtures that match test/fixtures/sample.srt.
set -euo pipefail
cd "$(dirname "$0")/fixtures"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=330:duration=60" -c:a aac -b:a 64k sample.m4a
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=60" -f lavfi -i "sine=frequency=440:duration=60" \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 35 -c:a aac -b:a 48k -shortest sample.mp4
echo "fixtures written to $(pwd)"
