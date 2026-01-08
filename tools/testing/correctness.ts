#!/usr/bin/env bun
/**
 * Clean correctness runner — staged, explicit, no packaging, no perf.
 *
 * Mental model (what we measure):
 *
 *   ZIG NATIVE
 *     zig build vm-baseline  → core VM must-pass gate
 *     zig build test         → full Zig unit/integration suite
 *     What it measures: native MathZig VM, parser, types, ODE, TS Zig-side, etc.
 *     Reference baseline for everything else.
 *
 *   BACKENDS (same expressions, one backend at a time)
 *     parity JSON cases run through:
 *       zig_vm      → native VM via parity adapter (should match zig tests for same exprs)
 *       ts_ffi      → TypeScript → FFI → native lib
 *       ts_wasm_vm  → TypeScript → WASM VM build
 *       wasm_aot    → compile expression to AOT wasm, run module
 *     What it measures: each backend returns the same value as the reference (zig_vm)
 *     for every case in tests/parity/cases/*.json (minus per-backend skips).
 *
 *   BOUNDARY (TS harness around native / wasm)
 *     Focused bun tests for FFI boundary, wasm wrapper, ABI — not the whole monorepo.
 *     What it measures: host bindings, memory, error paths that JSON vectors don't cover.
 *
 * Usage:
 *   bun tools/testing/correctness.ts              # all stages
 *   bun tools/testing/correctness.ts zig
 *   bun tools/testing/correctness.ts backends
 *   bun tools/testing/correctness.ts zig_vm       # single backend parity
 *   bun tools/testing/correctness.ts ts_ffi
 *   bun tools/testing/correctness.ts ts_wasm_vm
 *   bun tools/testing/correctness.ts wasm_aot
 *   bun tools/testing/correctness.ts boundary
 *   bun tools/testing/correctness.ts --quick      # parity --quick only
 *   bun tools/testing/correctness.ts --task-id=my_run
 *
 * Exit: non-zero if any selected stage fails. Prints a clear stage table at the end.
 */
import * as fs from "node:fs";
import * as path from "node:path";

type StageResult = {
  id: string;
  title: string;
  status: "PASS" | "FAIL" | "SKIP";
  durationSec: number;
  command: string;
  log?: string;
  note?: string;
};

const ROOT = process.cwd();
const ARTIFACTS = path.resolve(ROOT, "tests/artifacts/correctness");

const BACKENDS = ["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"] as const;
type Backend = (typeof BACKENDS)[number];

/** Focused TS boundary tests — host/FFI/WASM glue, not full bun test. */
const BOUNDARY_GLOBS = [
  "tests/ts/parity/ffi.test.ts",
  "tests/ts/parity/ffi_boundary_minimal.test.ts",
  "tests/ts/parity/ffi_boundary_validation.test.ts",
  "tests/ts/parity/test_ffi_basic.test.ts",
  "tests/ts/parity/wasm_abi.test.ts",
  "tests/ts/parity/wasm_memory.test.ts",
  "tests/ts/parity/wasm_wrapper_batch.test.ts",
  "tests/ts/parity/test_mathzig_wasm.test.ts",
  "tests/ts/aot_abi.test.ts",
  "tests/ts/aot_abi_json.test.ts",
  "tests/ts/aot_env.test.ts",
];

function parseArgs(argv: string[]) {
  let quick = false;
  let taskId = `correctness_${new Date().toISOString().replace(/[:.]/g, "").slice(0, 15)}`;
  const stages: string[] = [];

  for (const a of argv) {
    if (a === "--quick" || a === "-q") quick = true;
    else if (a.startsWith("--task-id=")) taskId = a.slice("--task-id=".length);
    else if (a === "--help" || a === "-h") {
      printHelp();
      process.exit(0);
    } else if (a.startsWith("-")) {
      console.error(`Unknown flag: ${a}`);
      process.exit(2);
    } else {
      stages.push(a);
    }
  }

  return { quick, taskId, stages };
}

function printHelp() {
  console.log(`Correctness runner (no packaging, no perf)

Stages:
  all          zig → each backend parity → boundary   (default)
  zig          vm-baseline + zig build test
  backends     parity for zig_vm, ts_ffi, ts_wasm_vm, wasm_aot (one at a time)
  zig_vm | ts_ffi | ts_wasm_vm | wasm_aot
               parity for that backend only (vs zig_vm reference when multi)
  boundary     focused FFI / WASM host tests

Flags:
  --quick              parity --quick
  --task-id=<id>       artifact label (default: timestamped)

Examples:
  bun tools/testing/correctness.ts
  bun tools/testing/correctness.ts zig
  bun tools/testing/correctness.ts ts_ffi
  bun tools/testing/correctness.ts backends --quick
  bun tools/testing/correctness.ts boundary

Perf is separate:
  bun tools/testing/measure.ts <feature_id> [zig|ts|all]
`);
}

function spawn(cmd: string[], logPath: string): { exit: number; durationSec: number } {
  const started = Date.now();
  const res = Bun.spawnSync({
    cmd,
    cwd: ROOT,
    env: process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const out =
    new TextDecoder().decode(res.stdout ?? new Uint8Array()) +
    new TextDecoder().decode(res.stderr ?? new Uint8Array());
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  fs.writeFileSync(logPath, out, "utf8");
  // Also stream a short tail to console for visibility
  const lines = out.split(/\r?\n/);
  const tail = lines.slice(-12).join("\n");
  if (tail.trim()) console.log(tail);
  return {
    exit: res.exitCode ?? 1,
    durationSec: Math.max(0, Math.round((Date.now() - started) / 1000)),
  };
}

function runStage(
  results: StageResult[],
  id: string,
  title: string,
  cmd: string[],
  note?: string
): boolean {
  const log = path.join(ARTIFACTS, `${id}.log`);
  console.log(`\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
  console.log(`▶ ${title}`);
  console.log(`  $ ${cmd.join(" ")}`);
  if (note) console.log(`  (${note})`);
  console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n`);

  const { exit, durationSec } = spawn(cmd, log);
  const status: StageResult["status"] = exit === 0 ? "PASS" : "FAIL";
  results.push({
    id,
    title,
    status,
    durationSec,
    command: cmd.join(" "),
    log: path.relative(ROOT, log),
    note,
  });
  console.log(`\n◀ ${title}: ${status} (${durationSec}s)`);
  if (status === "FAIL") {
    printParityFailureDigest(log);
  }
  console.log("");
  return exit === 0;
}

/** Surface parity report path + first failures so FAIL is not a black box. */
function printParityFailureDigest(stageLogPath: string) {
  try {
    const text = fs.readFileSync(stageLogPath, "utf8");
    const reportMatch = text.match(/Report:\s*(\S+)/);
    if (reportMatch) {
      const reportPath = reportMatch[1];
      const rel = path.relative(ROOT, reportPath);
      console.log(`  Report: ${rel}`);
      if (fs.existsSync(reportPath)) {
        const report = fs.readFileSync(reportPath, "utf8");
        const fails = report
          .split(/\r?\n/)
          .filter((l) => l.includes("**") && l.includes(":"))
          .slice(0, 12);
        if (fails.length) {
          console.log("  First failures:");
          for (const f of fails) console.log(`    ${f.replace(/^- /, "")}`);
          if (report.split("\n").filter((l) => l.startsWith("- **")).length > 12) {
            console.log("    … (see full report)");
          }
        }
      }
    }
    const mismatch = text.match(/Parity failed:\s*(\d+)\s*mismatches/);
    if (mismatch) console.log(`  Mismatches: ${mismatch[1]}`);
  } catch {
    /* ignore */
  }
}

function expandStages(requested: string[]): string[] {
  if (requested.length === 0 || requested.includes("all")) {
    return ["zig", ...BACKENDS, "boundary"];
  }
  const out: string[] = [];
  for (const s of requested) {
    if (s === "backends") out.push(...BACKENDS);
    else if (s === "zig" || s === "boundary" || (BACKENDS as readonly string[]).includes(s)) {
      out.push(s);
    } else {
      console.error(`Unknown stage: ${s}`);
      console.error(`Known: all, zig, backends, boundary, ${BACKENDS.join(", ")}`);
      process.exit(2);
    }
  }
  return out;
}

function main() {
  const { quick, taskId, stages: requested } = parseArgs(process.argv.slice(2));
  const plan = expandStages(requested);

  fs.mkdirSync(ARTIFACTS, { recursive: true });

  console.log(`\nMathZig correctness runner`);
  console.log(`task-id: ${taskId}`);
  console.log(`plan:    ${plan.join(" → ")}`);
  console.log(`parity:  ${quick ? "quick" : "full"}`);
  console.log(`logs:    ${path.relative(ROOT, ARTIFACTS)}/`);
  console.log(`\nWhat this measures:`);
  console.log(`  zig        → native VM / parser / types (source of truth)`);
  console.log(`  *_backend  → same JSON cases on that host path vs zig_vm`);
  console.log(`  boundary   → TS glue (FFI/WASM ABI), not full bun test`);
  console.log(`  (perf is NOT run here — use measure.ts)\n`);

  const results: StageResult[] = [];
  let failed = false;
  /** Only Zig abort is hard fail-fast — backends continue so the matrix is complete. */
  let zigFailed = false;

  for (const stage of plan) {
    if (zigFailed) {
      results.push({
        id: stage,
        title: stage,
        status: "SKIP",
        durationSec: 0,
        command: "",
        note: "skipped — zig source-of-truth failed",
      });
      continue;
    }

    if (stage === "zig") {
      const ok1 = runStage(
        results,
        "zig_vm_baseline",
        "Zig VM baseline (must-pass core)",
        ["zig", "build", "vm-baseline", "--summary", "all"],
        "Native core gate — Agents.md step 2"
      );
      if (!ok1) {
        failed = true;
        zigFailed = true;
        continue;
      }
      const ok2 = runStage(
        results,
        "zig_tests",
        "Zig unit/integration tests",
        ["zig", "build", "test", "--summary", "all"],
        "Full Zig suite under tests/zig + linked sources"
      );
      if (!ok2) {
        failed = true;
        zigFailed = true;
      }
      continue;
    }

    if ((BACKENDS as readonly string[]).includes(stage)) {
      const backend = stage as Backend;
      // Always include zig_vm as reference when running a non-zig backend so compare works.
      // When running zig_vm alone, only that backend (self-check + CSV).
      const backends =
        backend === "zig_vm" ? "zig_vm" : `zig_vm,${backend}`;
      const parityFlags = [
        "bun",
        "tests/parity/cli.ts",
        quick ? "--quick" : "--full",
        `--task-id=${taskId}_${backend}`,
        `--backends=${backends}`,
      ];
      const ok = runStage(
        results,
        `parity_${backend}`,
        `Parity: ${backend}${backend === "zig_vm" ? "" : " (vs zig_vm reference)"}`,
        parityFlags,
        backendExplain(backend)
      );
      // Backend fail: mark overall fail but CONTINUE other backends / boundary.
      if (!ok) failed = true;
      continue;
    }

    if (stage === "boundary") {
      const existing = BOUNDARY_GLOBS.filter((g) => fs.existsSync(path.resolve(ROOT, g)));
      if (existing.length === 0) {
        results.push({
          id: "boundary",
          title: "TS boundary (FFI / WASM host)",
          status: "SKIP",
          durationSec: 0,
          command: "",
          note: "no boundary test files found",
        });
        continue;
      }
      const ok = runStage(
        results,
        "boundary",
        "TS boundary (FFI / WASM host harness)",
        ["bun", "test", ...existing],
        "Host glue only — not full monorepo bun test"
      );
      if (!ok) failed = true;
      continue;
    }
  }

  // Summary table
  console.log(`\n╔══════════════════════════════════════════════════════════════╗`);
  console.log(`║  CORRECTNESS SUMMARY  task=${taskId.padEnd(36).slice(0, 36)}║`);
  console.log(`╠══════════════════════╤══════╤═══════╤════════════════════════╣`);
  console.log(`║ stage                │ ok   │ time  │ log                    ║`);
  console.log(`╟──────────────────────┼──────┼───────┼────────────────────────╢`);
  for (const r of results) {
    const st = r.status.padEnd(4);
    const t = `${r.durationSec}s`.padStart(5);
    const log = (r.log ?? "-").slice(0, 22).padEnd(22);
    console.log(`║ ${r.id.padEnd(20).slice(0, 20)} │ ${st} │ ${t} │ ${log} ║`);
  }
  console.log(`╚══════════════════════╧══════╧═══════╧════════════════════════╝`);

  const summaryPath = path.join(ARTIFACTS, `${taskId}_summary.json`);
  fs.writeFileSync(
    summaryPath,
    JSON.stringify(
      {
        task_id: taskId,
        finished_at: new Date().toISOString(),
        overall: failed ? "fail" : "pass",
        stages: results,
      },
      null,
      2
    ) + "\n",
    "utf8"
  );
  console.log(`\nWrote ${path.relative(ROOT, summaryPath)}`);

  if (failed) {
    console.log(`\nFAILED overall — see FAIL stages and their reports above.`);
    console.log(`  Zig fail  → fix native first; other stages were skipped.`);
    console.log(`  Backend fail → host path gaps vs zig_vm (not a CLI bug).`);
    console.log(`  Logs: ${path.relative(ROOT, ARTIFACTS)}/`);
    console.log(`Next (when green): bun run mz -- measure ${taskId} zig\n`);
    process.exit(1);
  }

  console.log(`\nPASSED correctness.`);
  console.log(`Next (perf only): bun tools/testing/measure.ts ${taskId} zig\n`);
  process.exit(0);
}

function backendExplain(b: Backend): string {
  switch (b) {
    case "zig_vm":
      return "Native VM via parity adapter — same expressions as JSON cases";
    case "ts_ffi":
      return "TS → FFI → libmathzig — host binding path";
    case "ts_wasm_vm":
      return "TS → WASM VM build — browser/node wasm interpreter path";
    case "wasm_aot":
      return "Compile expr → AOT wasm module → run — ahead-of-time path";
  }
}

main();
