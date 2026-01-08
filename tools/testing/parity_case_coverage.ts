#!/usr/bin/env bun
/**
 * Parity catalog coverage report (honest).
 *
 * Reports real inventory under tests/parity/cases/*.json:
 *   - file + case counts
 *   - per-backend catalog skip counts and runnable %
 *   - residual skip IDs for wasm_aot / standalone
 *
 * This is NOT a live execution harness (use `bun tests/parity/cli.ts` or `mz`).
 * Historical name `test:parity:coverage` used to only grep
 * tools/testing/parity_migration_map.md for TODO — that was dishonest.
 * Migration-map TODOs are listed as a secondary advisory section only.
 *
 * Usage:
 *   bun tools/testing/parity_case_coverage.ts
 *   bun tools/testing/parity_case_coverage.ts --json
 *
 * Exit 0 always when the catalog is readable (coverage is informational).
 * Exit 1 if the catalog is missing or malformed.
 */
import * as fs from "node:fs";
import * as path from "node:path";

const ROOT = process.cwd();
const CASES_DIR = path.join(ROOT, "tests/parity/cases");
const MIGRATION_MAP = path.join(ROOT, "tools/testing/parity_migration_map.md");
const BACKENDS = [
  "zig_vm",
  "ts_ffi",
  "ts_wasm_vm",
  "wasm_aot",
  "wasm_aot_standalone",
] as const;

type Case = { id: string; file: string; skip: string[] };

function loadCases(): Case[] {
  if (!fs.existsSync(CASES_DIR)) {
    throw new Error(`Missing parity catalog dir: ${CASES_DIR}`);
  }
  const files = fs
    .readdirSync(CASES_DIR)
    .filter((f) => f.endsWith(".json"))
    .sort();
  const cases: Case[] = [];
  for (const file of files) {
    const full = path.join(CASES_DIR, file);
    const raw = JSON.parse(fs.readFileSync(full, "utf8")) as unknown;
    if (!Array.isArray(raw)) {
      throw new Error(`Parity case file must be a JSON array: ${file}`);
    }
    for (const item of raw) {
      if (!item || typeof item !== "object") continue;
      const c = item as { id?: string; skip?: string[] };
      if (typeof c.id !== "string") continue;
      const skip = Array.isArray(c.skip)
        ? c.skip.filter((s) => typeof s === "string")
        : [];
      cases.push({ id: c.id, file, skip });
    }
  }
  return cases;
}

function skipsFor(c: Case, backend: string): boolean {
  if (c.skip.includes(backend)) return true;
  if (backend === "wasm_aot_standalone" && c.skip.includes("wasm_aot")) return true;
  return false;
}

function migrationTodos(): Array<{ line: number; text: string }> {
  if (!fs.existsSync(MIGRATION_MAP)) return [];
  return fs
    .readFileSync(MIGRATION_MAP, "utf8")
    .split(/\r?\n/)
    .map((text, i) => ({ line: i + 1, text }))
    .filter((e) => e.text.includes("TODO"));
}

function main() {
  const asJson = process.argv.includes("--json");
  let cases: Case[];
  try {
    cases = loadCases();
  } catch (e) {
    console.error(String(e));
    process.exit(1);
  }

  const files = new Set(cases.map((c) => c.file));
  const perBackend: Record<
    string,
    { skip: number; runnable: number; skipIds: string[] }
  > = {};
  for (const b of BACKENDS) {
    const skipIds = cases.filter((c) => skipsFor(c, b)).map((c) => c.id);
    perBackend[b] = {
      skip: skipIds.length,
      runnable: cases.length - skipIds.length,
      skipIds,
    };
  }

  const report = {
    kind: "parity_catalog_coverage",
    files: files.size,
    cases: cases.length,
    backends: Object.fromEntries(
      BACKENDS.map((b) => {
        const row = perBackend[b]!;
        return [
          b,
          {
            skip: row.skip,
            runnable: row.runnable,
            coverage_pct:
              cases.length === 0
                ? 0
                : Math.round((1000 * row.runnable) / cases.length) / 10,
            skip_ids: row.skipIds,
          },
        ];
      })
    ),
    migration_map_todos: migrationTodos().map((t) => ({
      line: t.line,
      text: t.text.trim(),
    })),
  };

  if (asJson) {
    console.log(JSON.stringify(report, null, 2));
    process.exit(0);
  }

  console.log("Parity catalog coverage (inventory — not live execution)");
  console.log("========================================================");
  console.log(`Files:  ${report.files}`);
  console.log(`Cases:  ${report.cases}`);
  console.log("");
  console.log(
    "Backend".padEnd(22) +
      "Runnable".padStart(10) +
      "Skip".padStart(8) +
      "Coverage".padStart(10)
  );
  for (const b of BACKENDS) {
    const row = report.backends[b] as {
      skip: number;
      runnable: number;
      coverage_pct: number;
      skip_ids: string[];
    };
    console.log(
      b.padEnd(22) +
        String(row.runnable).padStart(10) +
        String(row.skip).padStart(8) +
        `${row.coverage_pct}%`.padStart(10)
    );
  }
  console.log("");
  const aotSkips = (report.backends["wasm_aot"] as { skip_ids: string[] })
    .skip_ids;
  if (aotSkips.length) {
    console.log("wasm_aot catalog skips:");
    for (const id of aotSkips) console.log(`  - ${id}`);
    console.log("");
  }
  const todos = report.migration_map_todos as Array<{ line: number; text: string }>;
  console.log(
    `Advisory: parity_migration_map.md has ${todos.length} TODO line(s) (not a gate).`
  );
  if (todos.length) {
    for (const t of todos.slice(0, 20)) {
      console.log(`  ${t.line}: ${t.text}`);
    }
    if (todos.length > 20) console.log(`  … +${todos.length - 20} more`);
  }
  console.log("");
  console.log(
    "Live execution: bun tests/parity/cli.ts --full  ·  status: bun tools/status_report.ts"
  );
  process.exit(0);
}

main();
