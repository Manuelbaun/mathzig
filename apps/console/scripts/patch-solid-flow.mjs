#!/usr/bin/env node
/**
 * Patch @dschz/solid-flow 0.1.4 connection rubber-band start position.
 *
 * Upstream fix (dsnchz/solid-flow#21 / 30bff3b): do NOT re-project `from`
 * with pointToRendererPoint — that double-transforms and makes the
 * connection line start away from the source handle.
 *
 * npm still only has 0.1.4 (pre-fix). Run after install:
 *   node scripts/patch-solid-flow.mjs
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const targets = [
  "node_modules/@dschz/solid-flow/dist/index/index.js",
  "node_modules/@dschz/solid-flow/dist/index/index.jsx",
];

const needle =
  "from: state.inProgress ? pointToRendererPoint(state.from, this.transform) : state.from,";
const replacement = "from: state.from,";

let patched = 0;
let already = 0;
let missing = 0;

for (const rel of targets) {
  const file = path.join(root, rel);
  if (!fs.existsSync(file)) {
    missing++;
    continue;
  }
  const text = fs.readFileSync(file, "utf8");
  if (!text.includes(needle)) {
    if (text.includes("from: state.from,")) {
      already++;
      console.log(`ok (already patched): ${rel}`);
    } else {
      console.warn(`warn: pattern not found in ${rel}`);
    }
    continue;
  }
  fs.writeFileSync(file, text.replace(needle, replacement));
  patched++;
  console.log(`patched: ${rel}`);
}

if (patched === 0 && already === 0) {
  console.error("solid-flow connection patch failed (no files updated)");
  process.exit(1);
}
console.log(`solid-flow patch done (patched=${patched}, already=${already}, missing=${missing})`);
