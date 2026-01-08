#!/usr/bin/env bun
import * as fs from "node:fs";
import * as path from "node:path";
import { buildIndex } from "./build_index";

import { parseCsvText } from "./parse";
import { rowsToSnapshot } from "./snapshot";
import { ensurePerfDirs, PERF_LOG, SNAPSHOTS_DIR } from "./paths";

type Args = {
  feature: string;
  tier: string;
  mode: "all" | "zig" | "ts";
  tag: string | null;
  refsOnly: boolean;
  skipPerf: boolean;
};

function parseArgs(argv: string[]): Args {
  let feature = "baseline";
  let tier = "standard";
  let mode: Args["mode"] = "all";
  let tag: string | null = null;
  let refsOnly = false;
  let skipPerf = false;

  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--feature" || a === "-f") feature = argv[++i] ?? feature;
    else if (a === "--tier" || a === "-t") tier = argv[++i] ?? tier;
    else if (a === "--mode") mode = (argv[++i] as Args["mode"]) ?? mode;
    else if (a === "--tag") tag = argv[++i] ?? null;
    else if (a === "--refs-only") refsOnly = true;
    else if (a === "--skip-perf") skipPerf = true;
    else if (!a.startsWith("-") && feature === "baseline") feature = a;
  }

  return { feature, tier, mode, tag, refsOnly, skipPerf };
}

function spawn(cmd: string[], env?: NodeJS.ProcessEnv): { exit: number; stdout: string; stderr: string } {
  const res = Bun.spawnSync({ cmd, env, stdout: "pipe", stderr: "pipe" });
  const stdout = new TextDecoder().decode(res.stdout ?? new Uint8Array());
  const stderr = new TextDecoder().decode(res.stderr ?? new Uint8Array());
  return { exit: res.exitCode ?? 1, stdout, stderr };
}

/** Live stream stdout/stderr (for long measure runs). Still returns combined text. */
function spawnLive(cmd: string[], env?: NodeJS.ProcessEnv): { exit: number; text: string } {
  const res = Bun.spawnSync({
    cmd,
    env: env ?? process.env,
    stdout: "inherit",
    stderr: "inherit",
  });
  return { exit: res.exitCode ?? 1, text: "" };
}

function gitShortSha(): string {
  return spawn(["git", "rev-parse", "--short", "HEAD"]).stdout.trim() || "unknown";
}

function ensureRefBinaries(): number {
  fs.mkdirSync(path.join(process.cwd(), "zig-out/bin"), { recursive: true });

  const builds = [
    ["zig", "build-exe", "-OReleaseFast", "-lc", "tests/performance/bench_refs.zig", "-femit-bin=zig-out/bin/bench_refs"],
    ["zig", "cc", "-O3", "-std=c11", "bench/refs/mandelbrot.c", "-o", "zig-out/bin/bench_refs_c_mandelbrot"],
    ["zig", "cc", "-O3", "-std=c11", "bench/refs/binarytree.c", "-o", "zig-out/bin/bench_refs_c_binarytree"],
  ];

  for (const cmd of builds) {
    const res = spawn(cmd);
    if (res.exit !== 0) {
      console.error(`Reference bench build failed: ${cmd.join(" ")}`);
      process.stderr.write(res.stderr);
      return res.exit;
    }
  }
  return 0;
}

function appendRefRows(feature: string): number {
  const buildExit = ensureRefBinaries();
  if (buildExit !== 0) return buildExit;

  let status = 0;
  const runners = [
    ["./zig-out/bin/bench_refs", feature],
    ["./zig-out/bin/bench_refs_c_mandelbrot", feature],
    ["./zig-out/bin/bench_refs_c_binarytree", feature],
  ];

  for (const cmd of runners) {
    const run = spawn(cmd);
    if (run.exit !== 0) {
      console.error(`Reference bench failed: ${cmd.join(" ")}`);
      process.stderr.write(run.stderr);
      status = run.exit;
      continue;
    }
    const text = `${run.stdout}\n${run.stderr}`;
    const lines = text.split(/\r?\n/).filter((l) => l.includes(","));
    for (const line of lines) {
      fs.appendFileSync(PERF_LOG, `${line}\n`, "utf8");
    }
    console.log(`Recorded ${lines.length} rows from ${cmd[0]}`);
  }

  return status;
}

function writeSnapshot(feature: string, tier: string, tag: string | null) {
  if (!fs.existsSync(PERF_LOG)) {
    console.error("No performance log to snapshot");
    return 1;
  }

  const allRows = parseCsvText(fs.readFileSync(PERF_LOG, "utf8"));
  const featureRows = allRows.filter((r) => r.featureId === feature);
  if (featureRows.length === 0) {
    console.error(`No rows found for feature_id=${feature}`);
    return 1;
  }

  const snapshot = rowsToSnapshot(featureRows, {
    featureId: feature,
    tier,
    gitTag: tag,
    gitSha: gitShortSha(),
  });
  if (!snapshot) return 1;

  const safe = snapshot.snapshot.id.replace(/[^a-zA-Z0-9._-]+/g, "_");
  const out = path.join(SNAPSHOTS_DIR, `${safe}.json`);
  fs.writeFileSync(out, `${JSON.stringify(snapshot, null, 2)}\n`, "utf8");
  console.log(`Wrote snapshot ${path.relative(process.cwd(), out)} (${snapshot.results.length} results)`);
  buildIndex();
  return 0;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  ensurePerfDirs();

  console.log(`\n══ bench run ══`);
  console.log(`  feature=${args.feature}  tier=${args.tier}  mode=${args.mode}`);
  console.log(`  steps: record_performance → ref benches → snapshot\n`);

  let status = 0;

  if (!args.skipPerf && !args.refsOnly) {
    console.log(`▶ [bench] record_performance (${args.mode})`);
    const perf = spawnLive(
      ["bun", "tests/performance/record_performance.ts", args.feature, args.mode],
      process.env
    );
    if (perf.exit !== 0) {
      console.error(`✗ [bench] record_performance failed (exit ${perf.exit})`);
      status = perf.exit;
    } else {
      console.log(`✓ [bench] record_performance done`);
    }
  } else {
    console.log(`○ [bench] record_performance skipped`);
  }

  if (args.tier === "smoke" || args.tier === "standard" || args.tier === "full") {
    console.log(`▶ [bench] reference benches (C/Zig refs)`);
    const refExit = appendRefRows(args.feature);
    if (refExit !== 0) {
      console.error(`✗ [bench] reference benches failed`);
      status = refExit;
    } else {
      console.log(`✓ [bench] reference benches done`);
    }
  }

  console.log(`▶ [bench] write snapshot`);
  const snapExit = writeSnapshot(args.feature, args.tier, args.tag);
  if (snapExit !== 0) {
    console.error(`✗ [bench] snapshot failed`);
    status = snapExit;
  } else {
    console.log(`✓ [bench] snapshot done`);
  }

  if (status !== 0) process.exit(status);
  console.log("\n✓ Bench run complete.");
}

main();