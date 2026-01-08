#!/usr/bin/env bash
# Demo: run MathZig AOT modules with Wasmer CLI.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../common/out"

if ! command -v wasmer >/dev/null 2>&1; then
  echo "wasmer not found. Install: brew install wasmer  (or https://wasmer.io)" >&2
  exit 1
fi

if [[ ! -f "$OUT/mul.wasm" || ! -f "$OUT/min.wasm" ]]; then
  echo "Sample modules missing — compiling…"
  "$HERE/../common/compile.sh"
fi

echo "=== wasmer $(wasmer --version 2>/dev/null | head -1) ==="
echo
echo "--- inspect mul.wasm ---"
wasmer inspect "$OUT/mul.wasm"
echo
echo "--- mul: eval(3) for x*2 ---"
wasmer run "$OUT/mul.wasm" --invoke eval 3.0
echo
echo "--- sum3: eval(2,3,4) for x*y+z ---"
wasmer run "$OUT/sum3.wasm" --invoke eval 2.0 3.0 4.0
echo
echo "--- min: needs env.min (expected to FAIL on bare CLI) ---"
if wasmer run "$OUT/min.wasm" --invoke eval 3.0 1.0; then
  echo "(unexpected success)"
else
  echo
  echo "OK: Wasmer correctly requires host imports for env.min."
  echo "Use a Wasmer SDK linker to provide env.* (see README)."
fi
