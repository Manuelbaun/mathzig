#!/usr/bin/env bun
/**
 * MathZig test CLI — one command only.
 *
 *   bun run mz
 *
 * Runs full correctness → measure all backends → always records a progress
 * package and refreshes apps/progress dashboard data.
 *
 * No feature_id / task_id. Run identity is git HEAD (short sha).
 * Not an app launcher.
 */
import { Command } from "commander";
import * as fs from "node:fs";
import * as path from "node:path";
import { runPipeline, type PipelineOptions } from "../testing/pipeline.ts";

const ROOT = process.cwd();

function readVersion(): string {
  try {
    return fs.readFileSync(path.join(ROOT, "src/VERSION"), "utf8").trim() || "0.0.0";
  } catch {
    return "0.0.0";
  }
}

const program = new Command();

program
  .name("mz")
  .description(
    `MathZig test pipeline (one way only)

  bun run mz

Always:
  1. correctness  — zig baseline + zig tests + boundary + all-backend parity
  2. measure      — zig + ts throughput (all backends)
  3. record       — progress package + apps/progress public data

No feature_id / task_id.
Automatic tag = {branch}__{UTC_time}__{short_sha}
Dashboard visualizes history: apps/progress`
  )
  .version(readVersion())
  .option("-q, --quick", "parity --quick (default: full)")
  .option("--skip-measure", "correctness + package only (no perf)")
  .option("--samples <n>", "PERF_SAMPLES")
  .option("--warmup <n>", "PERF_WARMUP")
  .action(async (opts: {
    quick?: boolean;
    skipMeasure?: boolean;
    samples?: string;
    warmup?: string;
  }) => {
    const pipelineOpts: PipelineOptions = {
      quick: opts.quick,
      skipMeasure: opts.skipMeasure,
      samples: opts.samples,
      warmup: opts.warmup,
    };
    const result = await runPipeline(pipelineOpts);
    process.exit(result.exitCode);
  });

program
  .command("where")
  .description("Where artifacts and dashboard data live")
  .action(() => {
    const rows = [
      ["runs", "tests/artifacts/runs/<branch>__<time>__<hash>/"],
      ["parity CSVs", "tests/artifacts/parity/"],
      ["perf CSV", "tests/artifacts/performance/performance_log.csv"],
      ["perf snapshots", "tests/artifacts/performance/snapshots/"],
      ["progress packages", "tests/artifacts/progress/packages/"],
      ["progress index", "tests/artifacts/progress/index.json"],
      ["dashboard data", "apps/progress/public/data/"],
      ["dashboard app", "apps/progress (bun run dev)"],
    ];
    console.log("\nArtifacts (written by `bun run mz`):\n");
    for (const [k, v] of rows) console.log(`  ${k.padEnd(20)} ${v}`);
    console.log("");
  });

program
  .command("help-extra")
  .description("Hidden escapes for maintainers (not the daily path)")
  .action(() => {
    console.log(`
Daily path (only this):
  bun run mz

Maintainer escapes (prefer not):
  bun tools/testing/correctness.ts          # correctness stages only
  bun tools/testing/measure.ts <auto-id> all
  bun tools/progress/write_package.ts <id>
  bun tools/progress/build_app_data.ts
  bun tools/testing/feature_gate.ts …       # legacy multi-option gate

Docs: docs/guides/testing.md · AGENTS.md
`);
  });

program.parse(process.argv);
