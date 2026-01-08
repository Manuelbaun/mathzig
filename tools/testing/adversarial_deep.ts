#!/usr/bin/env bun
/**
 * Nightly deep adversarial run (task-14 / C3).
 *
 * Named optional scope: **adversarial_deep** (not part of the mandatory mz gate).
 *
 * Usage:
 *   bun tools/testing/adversarial_deep.ts
 *   bun tools/testing/adversarial_deep.ts --seed=0x4d415448 --count=5000 --deadline-ms=2000
 */

import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

function argValue(name: string, fallback: string): string {
  const prefix = `--${name}=`;
  const hit = process.argv.find((a) => a.startsWith(prefix));
  return hit ? hit.slice(prefix.length) : fallback;
}

const seed = argValue("seed", `0x${(Date.now() & 0xffffffff).toString(16)}`);
const count = argValue("count", "5000");
const deadlineMs = Number(argValue("deadline-ms", "120000"));

const root = resolve(import.meta.dir, "../..");
const env = {
  ...process.env,
  ADVERSARIAL_DEEP: "1",
  ADVERSARIAL_SEED: seed,
  ADVERSARIAL_COUNT: count,
  PATH: `${resolve(root, "tools/macos-sdk-shim")}:${process.env.PATH ?? ""}`,
};

console.log(`adversarial_deep scope seed=${seed} count=${count} deadline_ms=${deadlineMs}`);

const tests = [
  "tests/ts/adversarial/s1_dsl_fuzz.test.ts",
  "tests/ts/adversarial/s2_wire_fuzz.test.ts",
  "tests/ts/adversarial/s3_manifest_fuzz.test.ts",
  "tests/ts/adversarial/s4_graph_json_fuzz.test.ts",
];

const t0 = performance.now();
const r = spawnSync("bun", ["test", ...tests], {
  cwd: root,
  env,
  encoding: "utf8",
  timeout: deadlineMs,
  killSignal: "SIGKILL",
});
const ms = performance.now() - t0;

if (r.error && (r.error as NodeJS.ErrnoException).code === "ETIMEDOUT") {
  console.error(`adversarial_deep: TIMEOUT after ${deadlineMs}ms`);
  process.exit(1);
}
if (r.status !== 0) {
  console.error(r.stdout);
  console.error(r.stderr);
  console.error(`adversarial_deep: FAIL status=${r.status} (${ms.toFixed(0)}ms)`);
  process.exit(r.status ?? 1);
}

// Zig surface (S3/S4) under safety checks
const z = spawnSync("zig", ["build", "test", "-Doptimize=Debug"], {
  cwd: root,
  env,
  encoding: "utf8",
  timeout: deadlineMs,
  killSignal: "SIGKILL",
});
if (z.status !== 0) {
  console.error(z.stdout);
  console.error(z.stderr);
  console.error(`adversarial_deep: zig test FAIL status=${z.status}`);
  process.exit(z.status ?? 1);
}

console.log(`adversarial_deep: PASS (${ms.toFixed(0)}ms bun + zig debug)`);
