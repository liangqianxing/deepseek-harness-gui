#!/bin/zsh
set -euo pipefail

PORT="${1:-3080}"
HOST="127.0.0.1"
SCRIPT_DIR="${0:A:h}"
BUNDLED_RUNTIME="$SCRIPT_DIR/runtime"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

if [[ -x "$BUNDLED_RUNTIME/node" && -f "$BUNDLED_RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js" ]]; then
  exec "$BUNDLED_RUNTIME/node" "$BUNDLED_RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js" web --host "$HOST" --port "$PORT"
fi

if command -v dsh >/dev/null 2>&1; then
  exec dsh web --host "$HOST" --port "$PORT"
fi

exec npx --yes @deepseek-ai/dsh@0.1.0-rc.7 web --host "$HOST" --port "$PORT"
