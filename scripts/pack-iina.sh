#!/bin/sh
# Pack the IINA plugin into dist/cueline.iinaplgz for a GitHub release.
# IINA's "Install from GitHub" picks up the .iinaplgz asset of the latest release.
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
iina_plugin=/Applications/IINA.app/Contents/MacOS/iina-plugin
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$repo/iina" "$work/cueline"
(cd "$work" && "$iina_plugin" pack cueline)
mkdir -p "$repo/dist"
mv "$work"/*.iinaplgz "$repo/dist/cueline.iinaplgz"
echo "$repo/dist/cueline.iinaplgz"
