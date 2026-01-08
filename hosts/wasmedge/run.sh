#!/usr/bin/env bash
# Demo: run MathZig AOT modules with WasmEdge CLI.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../common/out"

if ! command -v wasmedge >/dev/null 2>&1; then
  echo "wasmedge not found." >&2
  echo "Install: brew install wasmedge" >&2
  echo "  or: https://wasmedge.org/docs/start/install" >&2
  exit 1
fi

if [[ ! -f "$OUT/mul.wasm" || ! -f "$OUT/sum3.wasm" ]]; then
  echo "Sample modules missing — compiling…"
  "$HERE/../common/compile.sh"
fi

echo "=== wasmedge $(wasmedge --version 2>/dev/null | head -1) ==="
echo

run_eval() {
  local wasm="$1"
  shift
  # Prefer reactor mode (function export, not _start).
  if wasmedge --reactor "$wasm" eval "$@" 2>/dev/null; then
    return 0
  fi
  # Older / alternate CLIs
  if wasmedge run --reactor "$wasm" eval "$@" 2>/dev/null; then
    return 0
  fi
  echo "Could not invoke eval on $wasm with this WasmEdge build." >&2
  echo "Try: wasmedge --help | head -40" >&2
  wasmedge --reactor "$wasm" eval "$@" # show real error
}

echo "--- mul: eval(3) for x*2 ---"
run_eval "$OUT/mul.wasm" 3.0
echo
echo "--- sum3: eval(2,3,4) for x*y+z ---"
run_eval "$OUT/sum3.wasm" 2.0 3.0 4.0
echo
echo "--- min: needs env.min (expected to FAIL on bare CLI) ---"
if run_eval "$OUT/min.wasm" 3.0 1.0; then
  echo "(unexpected success)"
else
  echo
  echo "OK: WasmEdge correctly requires host imports for env.min."
fi
