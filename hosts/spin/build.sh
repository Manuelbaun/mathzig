#!/usr/bin/env bash
# Compile sample AOT modules and build the Spin component.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

export PATH="${PATH}:$HOME/.local/bin:/opt/homebrew/bin"

if ! command -v spin >/dev/null 2>&1; then
  echo "spin not found. Install: https://spinframework.dev/install" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo/rustc not found. Install Rust: https://rustup.rs" >&2
  exit 1
fi

if ! rustup target list --installed 2>/dev/null | grep -q 'wasm32-wasip2'; then
  echo "Adding rustup target wasm32-wasip2…"
  rustup target add wasm32-wasip2
fi

"$HERE/../common/compile.sh"
mkdir -p "$HERE/wasm"
cp "$HERE/../common/out/mul.wasm" "$HERE/../common/out/min.wasm" "$HERE/wasm/"

echo
echo "Building Spin component…"
cd "$HERE"
spin build
echo
echo "OK. Run: ./hosts/spin/run.sh"
