#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DeepSeek Harness GUI"
APP_VERSION="0.1.0"
NODE_VERSION="22.23.1"
DIST_APP="$ROOT/dist/$APP_NAME.app"
INSTALL_APP="${INSTALL_APP:-$HOME/Applications/$APP_NAME.app}"
INSTALL_LOCAL="${INSTALL_LOCAL:-1}"
RUNTIME_CACHE="${RUNTIME_CACHE:-$ROOT/.runtime-cache}"
NPM_CACHE="${NPM_CACHE:-$RUNTIME_CACHE/npm}"
STAGE_ROOT="$(mktemp -d "$ROOT/.build.XXXXXX")"
APP="$STAGE_ROOT/$APP_NAME.app"

cleanup() {
  rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT

case "$(uname -m)" in
  arm64)
    NODE_ARCH="arm64"
    NODE_SHA256="ef28d8fab2c0e4314522d4bb1b7173270aa3937e93b92cb7de79c112ac1fa953"
    ;;
  x86_64)
    NODE_ARCH="x64"
    NODE_SHA256="b8da981b8a0b1241b70249204916da76c63573ddf5814dbd2d1e41069105cb81"
    ;;
  *)
    printf 'Unsupported macOS architecture: %s\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

NODE_ARCHIVE="node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
NODE_URL="https://nodejs.org/dist/v$NODE_VERSION/$NODE_ARCHIVE"
NODE_ARCHIVE_PATH="$RUNTIME_CACHE/node/$NODE_ARCHIVE"
NODE_DIST="$STAGE_ROOT/node"

mkdir -p "${NODE_ARCHIVE_PATH:h}" "$NODE_DIST"
download_node_archive() {
  local download_path="$NODE_ARCHIVE_PATH.download"
  curl --fail --location --retry 3 "$NODE_URL" --output "$download_path"
  mv "$download_path" "$NODE_ARCHIVE_PATH"
}

if [[ ! -f "$NODE_ARCHIVE_PATH" ]]; then
  download_node_archive
fi

ACTUAL_NODE_SHA256="$(shasum -a 256 "$NODE_ARCHIVE_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_NODE_SHA256" != "$NODE_SHA256" ]]; then
  printf 'Cached Node archive failed verification; downloading it again.\n' >&2
  download_node_archive
  ACTUAL_NODE_SHA256="$(shasum -a 256 "$NODE_ARCHIVE_PATH" | awk '{print $1}')"
  if [[ "$ACTUAL_NODE_SHA256" != "$NODE_SHA256" ]]; then
    printf 'Node archive checksum mismatch for %s.\n' "$NODE_ARCHIVE_PATH" >&2
    exit 1
  fi
fi

tar -xzf "$NODE_ARCHIVE_PATH" -C "$NODE_DIST" --strip-components 1
NODE_BIN="$NODE_DIST/bin/node"
NPM_CLI="$NODE_DIST/lib/node_modules/npm/bin/npm-cli.js"
DSH_VERSION="$("$NODE_BIN" -e '
const manifest = require(process.argv[1]);
process.stdout.write(manifest.dependencies["@deepseek-ai/dsh"]);
' "$ROOT/Runtime/package.json")"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime"

xcrun swiftc \
  -swift-version 5 \
  -O \
  -framework Cocoa \
  -framework WebKit \
  "$ROOT/Sources/main.swift" \
  -o "$APP/Contents/MacOS/DeepSeekHarnessGUI"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/start-dsh.sh" "$APP/Contents/Resources/start-dsh.sh"
chmod 755 "$APP/Contents/MacOS/DeepSeekHarnessGUI" "$APP/Contents/Resources/start-dsh.sh"

# Build the runtime from the checked-in lockfile so Finder launches do not
# depend on the user's PATH or on a previously generated local runtime.
ditto "$NODE_BIN" "$APP/Contents/Resources/runtime/node"
cp "$NODE_DIST/LICENSE" "$APP/Contents/Resources/runtime/NODE-LICENSE"
cp "$ROOT/Runtime/package.json" "$APP/Contents/Resources/runtime/package.json"
cp "$ROOT/Runtime/package-lock.json" "$APP/Contents/Resources/runtime/package-lock.json"
"$NODE_BIN" "$NPM_CLI" ci \
  --prefix "$APP/Contents/Resources/runtime" \
  --omit=dev \
  --ignore-scripts \
  --no-audit \
  --no-fund \
  --cache "$NPM_CACHE"

ACTUAL_DSH_VERSION="$(
  "$APP/Contents/Resources/runtime/node" \
    "$APP/Contents/Resources/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js" \
    --version
)"
if [[ "$ACTUAL_DSH_VERSION" != "$DSH_VERSION" ]]; then
  printf 'Expected dsh %s, found %s.\n' "$DSH_VERSION" "$ACTUAL_DSH_VERSION" >&2
  exit 1
fi

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

publish_app() {
  local target="$1"
  local parent="${target:h}"
  local publish_root candidate backup

  mkdir -p "$parent"
  publish_root="$(mktemp -d "$parent/.dsh-gui-publish.XXXXXX")"
  candidate="$publish_root/$APP_NAME.app"
  backup="$publish_root/previous.app"
  ditto "$APP" "$candidate"
  codesign --verify --deep --strict "$candidate"

  if [[ -e "$target" ]]; then
    mv "$target" "$backup"
  fi
  if ! mv "$candidate" "$target"; then
    if [[ -e "$backup" ]]; then
      mv "$backup" "$target"
    fi
    rm -rf "$publish_root"
    return 1
  fi
  rm -rf "$publish_root"
}

publish_app "$DIST_APP"
if [[ "$INSTALL_LOCAL" == "1" ]]; then
  publish_app "$INSTALL_APP"
  codesign --verify --deep --strict "$INSTALL_APP"
  printf '%s\n' "$INSTALL_APP"
else
  printf '%s\n' "$DIST_APP"
fi
