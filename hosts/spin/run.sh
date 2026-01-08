#!/usr/bin/env bash
# Start the Spin app and print curl examples.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LISTEN="${SPIN_LISTEN:-127.0.0.1:3458}"
export PATH="${PATH}:$HOME/.local/bin:/opt/homebrew/bin"

if [[ ! -f "$HERE/target/wasm32-wasip2/release/mathzig_aot_spin.wasm" ]]; then
  echo "Component not built yet — running build.sh…"
  "$HERE/build.sh"
fi

cd "$HERE"
echo "Serving on http://${LISTEN}"
echo
echo "  curl -s http://${LISTEN}/"
echo "  curl -s http://${LISTEN}/info"
echo "  curl -s 'http://${LISTEN}/mul?x=3'"
echo "  curl -s 'http://${LISTEN}/min?x=3&y=1'"
echo
exec spin up --listen "$LISTEN"
