#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH_PATH="$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-gui-check.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_PATH"
}
trap cleanup EXIT

zsh -n "$ROOT/build.sh" "$ROOT/Resources/start-dsh.sh" "$ROOT/scripts/check.sh"
plutil -lint "$ROOT/Resources/Info.plist"
ICONSET="$SCRATCH_PATH/AppIcon.iconset"
swift "$ROOT/scripts/generate-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$SCRATCH_PATH/AppIcon.icns"
test -s "$SCRATCH_PATH/AppIcon.icns"
swift build --package-path "$ROOT" --scratch-path "$SCRATCH_PATH" -c release
