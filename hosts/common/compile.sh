#!/usr/bin/env bash
# Compile sample MathZig AOT modules into hosts/common/out/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(cd "$(dirname "$0")" && pwd)/out"
BIN="${MATHZIG_BIN:-$ROOT/zig-out/bin/mathzig}"

if [[ ! -x "$BIN" ]]; then
  echo "mathzig binary not found: $BIN" >&2
  echo "From repo root: zig build" >&2
  exit 1
fi

mkdir -p "$OUT"

compile() {
  local name="$1"
  local expr="$2"
  local params="$3"
  local src="$OUT/${name}.mz"
  local wasm="$OUT/${name}.wasm"
  printf '%s\n' "$expr" >"$src"
  echo "compile $name: $expr  (-p $params)"
  "$BIN" compile -i "$src" -o "$wasm" -p "$params"
}

compile mul  'x * 2'     1
compile min  'min(x, y)' 2
compile sum3 'x * y + z' 3

echo
echo "Wrote modules to $OUT"
if command -v wasmer >/dev/null 2>&1; then
  wasmer inspect "$OUT/mul.wasm" || true
  wasmer inspect "$OUT/min.wasm" || true
elif command -v wasm-objdump >/dev/null 2>&1; then
  wasm-objdump -x "$OUT/mul.wasm" | head -40 || true
fi

echo
echo "Done."
