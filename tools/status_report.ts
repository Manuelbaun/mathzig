#!/usr/bin/env bun
/**
 * Generate docs/STATUS.md from repo inventory + structured test artifacts.
 *
 * Spec: docs/guides/quality.md (docs truth / STATUS generation)
 *
 *   bun tools/status_report.ts              # write docs/STATUS.md
 *   bun tools/status_report.ts --check      # assert on-disk matches regen (idempotence)
 *   bun tools/status_report.ts --stdout     # print only
 *
 * Deterministic at a fixed git revision: stamp uses commit ISO date + HEAD +
 * branch + hostname. Live gate/parity numbers come from artifact JSON/CSV when
 * present; otherwise inventory-only sections are emitted with "artifact absent".
 *
 * Does not re-run the full suite (use `bun run mz` for that). Consumes:
 *   - tests/artifacts/strict_bun_gate.json   (task-12)
 *   - tests/artifacts/parity/*_*.csv         (parity CLI)
 *   - tests/known_failures.json
 *   - tests/parity/cases/*.json
 *   - tests/parity/mathjs_examples/translated/**
 *   - tests/graph/goldens/*.json            (task-13 corpus)
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";

const ROOT = process.cwd();
const STATUS_PATH = path.join(ROOT, "docs/STATUS.md");
const ARTIFACTS = path.join(ROOT, "tests/artifacts");
const STRICT_JSON = path.join(ARTIFACTS, "strict_bun_gate.json");
const PARITY_DIR = path.join(ARTIFACTS, "parity");
const CASES_DIR = path.join(ROOT, "tests/parity/cases");
const MATHJS_DIR = path.join(ROOT, "tests/parity/mathjs_examples/translated");
const GOLDENS_DIR = path.join(ROOT, "tests/graph/goldens");
const KNOWN_FAILURES = path.join(ROOT, "tests/known_failures.json");

const BACKENDS = ["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"] as const;
const STANDALONE = "wasm_aot_standalone";
const GRAPH_MODES = ["ts_wasm", "native_vm", "zig_vm", "native_wasm"] as const;

type BackendTotals = {
  pass: number;
  fail: number;
  skip: number;
  total: number;
  source: "artifact" | "inventory";
};

type InventoryCase = {
  id: string;
  file: string;
  skip: string[];
};

function git(args: string[]): string {
  const r = spawnSync("git", args, { cwd: ROOT, encoding: "utf8" });
  if (r.status !== 0) return "";
  return (r.stdout ?? "").trim();
}

function stamp(): {
  revision: string;
  short: string;
  branch: string;
  timestamp: string;
  machine: string;
  dirty: boolean;
} {
  // Evidence revision = last commit that touched anything except docs/STATUS.md.
  // That keeps the stamp stable when the only follow-up commit is STATUS itself
  // (self-referential HEAD would break same-revision idempotence forever).
  const revision =
    process.env.STATUS_STAMP_REV ||
    git(["log", "-1", "--format=%H", "--", ".", ":!docs/STATUS.md"]) ||
    git(["rev-parse", "HEAD"]) ||
    "unknown";
  const short =
    process.env.STATUS_STAMP_REV?.slice(0, 7) ||
    git(["log", "-1", "--format=%h", "--", ".", ":!docs/STATUS.md"]) ||
    git(["rev-parse", "--short", "HEAD"]) ||
    revision.slice(0, 7);
  const branch =
    git(["rev-parse", "--abbrev-ref", "HEAD"]) ||
    process.env.GIT_BRANCH ||
    "unknown";
  // Commit date of the evidence revision (stable for same content rev).
  const timestamp =
    git(["show", "-s", "--format=%cI", revision]) ||
    git(["show", "-s", "--format=%cI", "HEAD"]) ||
    "1970-01-01T00:00:00Z";
  // Dirty if anything other than docs/STATUS.md is modified (STATUS is the output).
  const dirtyLines = git(["status", "--porcelain"])
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .filter((l) => !l.endsWith(" docs/STATUS.md") && !l.endsWith("\tdocs/STATUS.md"));
  const dirty = dirtyLines.length > 0;
  return {
    revision,
    short,
    branch,
    timestamp,
    machine: os.hostname(),
    dirty,
  };
}

function loadJson<T>(p: string): T | null {
  if (!fs.existsSync(p)) return null;
  try {
    return JSON.parse(fs.readFileSync(p, "utf8")) as T;
  } catch {
    return null;
  }
}

function loadParityInventory(): {
  files: number;
  cases: InventoryCase[];
  skipByBackend: Record<string, number>;
  filesList: string[];
} {
  if (!fs.existsSync(CASES_DIR)) {
    return { files: 0, cases: [], skipByBackend: {}, filesList: [] };
  }
  const filesList = fs
    .readdirSync(CASES_DIR)
    .filter((f) => f.endsWith(".json"))
    .sort();
  const cases: InventoryCase[] = [];
  const skipByBackend: Record<string, number> = {};
  for (const file of filesList) {
    const raw = JSON.parse(
      fs.readFileSync(path.join(CASES_DIR, file), "utf8")
    ) as unknown;
    if (!Array.isArray(raw)) continue;
    for (const item of raw) {
      if (!item || typeof item !== "object") continue;
      const c = item as { id?: string; skip?: string[] };
      if (typeof c.id !== "string") continue;
      const skip = Array.isArray(c.skip)
        ? c.skip.filter((s) => typeof s === "string")
        : [];
      cases.push({ id: c.id, file, skip });
      for (const s of skip) {
        skipByBackend[s] = (skipByBackend[s] ?? 0) + 1;
      }
    }
  }
  return { files: filesList.length, cases, skipByBackend, filesList };
}

function parseParityCsv(csvPath: string): BackendTotals | null {
  if (!fs.existsSync(csvPath)) return null;
  const lines = fs.readFileSync(csvPath, "utf8").split(/\r?\n/).filter(Boolean);
  if (lines.length <= 1) return null;
  let pass = 0;
  let fail = 0;
  let skip = 0;
  for (const line of lines.slice(1)) {
    // id,expr,status,reason — status is third column; expr may contain commas in quotes
    const m = line.match(/,(PASS|FAIL|SKIP),/);
    if (!m) continue;
    if (m[1] === "PASS") pass += 1;
    else if (m[1] === "FAIL") fail += 1;
    else skip += 1;
  }
  return { pass, fail, skip, total: pass + fail + skip, source: "artifact" };
}

function findLatestParityCsvs(): Record<string, string> {
  const out: Record<string, string> = {};
  if (!fs.existsSync(PARITY_DIR)) return out;
  const known = [...BACKENDS, STANDALONE];
  // Prefer newest mtime per backend (not lexicographic task-id). Match known
  // backend suffixes only (cannot split on last `_` — zig_vm has underscores).
  const files = fs.readdirSync(PARITY_DIR).filter((f) => f.endsWith(".csv"));
  const bestMtime: Record<string, number> = {};
  for (const f of files) {
    for (const backend of known) {
      if (f === `${backend}.csv` || f.endsWith(`_${backend}.csv`)) {
        const full = path.join(PARITY_DIR, f);
        const mtime = fs.statSync(full).mtimeMs;
        if (bestMtime[backend] === undefined || mtime >= bestMtime[backend]!) {
          bestMtime[backend] = mtime;
          out[backend] = full;
        }
      }
    }
  }
  return out;
}

function inventoryBackendTotals(
  inv: ReturnType<typeof loadParityInventory>
): Record<string, BackendTotals> {
  const totals: Record<string, BackendTotals> = {};
  for (const b of [...BACKENDS, STANDALONE]) {
    const skip = inv.cases.filter((c) => {
      if (c.skip.includes(b)) return true;
      if (b === STANDALONE && c.skip.includes("wasm_aot")) return true;
      return false;
    }).length;
    const runnable = inv.cases.length - skip;
    totals[b] = {
      pass: 0,
      fail: 0,
      skip,
      total: inv.cases.length,
      source: "inventory",
    };
    // Without artifacts we cannot claim pass/fail — leave pass as runnable unknown.
    void runnable;
  }
  return totals;
}

function loadMathJsTotals(): {
  files: number;
  core: number;
  extended: number;
  unsupported: number;
  total: number;
  crash: number;
} {
  let files = 0;
  let core = 0;
  let extended = 0;
  let unsupported = 0;
  let total = 0;
  let crash = 0;
  if (!fs.existsSync(MATHJS_DIR)) {
    return { files, core, extended, unsupported, total, crash };
  }
  const walk = (dir: string) => {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, ent.name);
      if (ent.isDirectory()) walk(p);
      else if (ent.name.endsWith(".json")) {
        files += 1;
        const d = JSON.parse(fs.readFileSync(p, "utf8")) as {
          cases?: Array<{ tier?: string; hazard?: string }>;
        };
        for (const c of d.cases ?? []) {
          total += 1;
          const tier = c.tier ?? "?";
          if (tier === "core") core += 1;
          else if (tier === "extended") extended += 1;
          else if (tier === "unsupported") unsupported += 1;
          if (c.hazard === "crash") crash += 1;
        }
      }
    }
  };
  walk(MATHJS_DIR);
  return { files, core, extended, unsupported, total, crash };
}

function loadGraphCorpus(): {
  files: string[];
  cases: Array<{ id: string; form: string; file: string }>;
  matrix: Array<{
    id: string;
    form: string;
    ts_wasm: string;
    native_vm: string;
    zig_vm: string;
    native_wasm: string;
  }>;
} {
  const files = fs.existsSync(GOLDENS_DIR)
    ? fs.readdirSync(GOLDENS_DIR).filter((f) => f.endsWith(".json")).sort()
    : [];
  const cases: Array<{ id: string; form: string; file: string }> = [];
  for (const file of files) {
    const raw = JSON.parse(
      fs.readFileSync(path.join(GOLDENS_DIR, file), "utf8")
    ) as
      | { id?: string; form?: string; cases?: Array<{ id: string; form: string }> }
      | Array<{ id: string; form: string }>;
    if (Array.isArray(raw)) {
      for (const c of raw) cases.push({ id: c.id, form: c.form, file });
    } else if (raw && typeof raw === "object" && Array.isArray(raw.cases)) {
      for (const c of raw.cases) cases.push({ id: c.id, form: c.form, file });
    } else if (raw && typeof raw === "object" && typeof raw.id === "string") {
      cases.push({
        id: raw.id,
        form: typeof raw.form === "string" ? raw.form : "success",
        file,
      });
    }
  }
  // Contract from task-13: success goldens run on ts_wasm/native_vm/zig_vm;
  // native_wasm is phase-2 skip; load_error goldens skip zig_vm composed oracle.
  const matrix = cases.map((c) => {
    if (c.form === "load_error") {
      return {
        id: c.id,
        form: c.form,
        ts_wasm: "expect_error",
        native_vm: "expect_error",
        zig_vm: "n/a",
        native_wasm: "skip:phase2",
      };
    }
    return {
      id: c.id,
      form: c.form,
      ts_wasm: "run",
      native_vm: "run",
      zig_vm: "oracle",
      native_wasm: "skip:phase2_native_wasm_interpreter",
    };
  });
  return { files, cases, matrix };
}

type StrictReport = {
  ok?: boolean;
  observed_fails?: string[];
  quarantined?: string[];
  unexpected_fail?: string[];
  unexpected_pass?: string[];
  stale?: string[];
  summary_line?: string;
  raw_exit?: number;
};

type KnownFailures = {
  entries?: Array<{
    id: string;
    suite?: string;
    scope?: string;
    kind?: string;
    reason?: string;
    since?: string;
    ticket_or_decision?: string;
  }>;
  standalone_skip_budget?: {
    max_skips?: number;
    max_fails?: number;
    note?: string;
  };
};

function mdEscape(s: string): string {
  return s.replace(/\|/g, "\\|");
}

export function buildStatusMarkdown(): string {
  const s = stamp();
  const inv = loadParityInventory();
  const mathjs = loadMathJsTotals();
  const graph = loadGraphCorpus();
  const kf = loadJson<KnownFailures>(KNOWN_FAILURES) ?? {};
  const strict = loadJson<StrictReport>(STRICT_JSON);
  const csvs = findLatestParityCsvs();
  const invTotals = inventoryBackendTotals(inv);

  const backendRows: Array<{
    name: string;
    totals: BackendTotals;
    catalogSkip: number;
  }> = [];
  for (const b of [...BACKENDS, STANDALONE]) {
    const fromCsv = csvs[b] ? parseParityCsv(csvs[b]!) : null;
    const catalogSkip = inv.cases.filter((c) => {
      if (c.skip.includes(b)) return true;
      if (b === STANDALONE && c.skip.includes("wasm_aot")) return true;
      return false;
    }).length;
    backendRows.push({
      name: b,
      totals: fromCsv ?? invTotals[b]!,
      catalogSkip,
    });
  }

  const commands = [
    "bun tools/status_report.ts",
    "bun tools/testing/strict_bun_gate.ts  # → tests/artifacts/strict_bun_gate.json",
    "bun tests/parity/cli.ts --full        # → tests/artifacts/parity/<task>_<backend>.csv",
    "bun tests/parity/cli.ts --standalone  # standalone totals when enabled",
    "bun run mz                            # full correctness + measure + progress",
  ];

  const lines: string[] = [];
  lines.push("# MathZig status report");
  lines.push("");
  lines.push(
    "> **Single status source of truth.** Capability docs: `docs/guides/capabilities.md`. Criterion-level claims live here. Regenerated by `bun tools/status_report.ts`."
  );
  lines.push("");
  lines.push("## Stamp");
  lines.push("");
  lines.push("| Field | Value |");
  lines.push("|-------|-------|");
  lines.push(
    `| Evidence revision | \`${s.revision}\` (\`${s.short}\`) — last commit excluding \`docs/STATUS.md\` |`
  );
  lines.push(`| Branch | \`${s.branch}\` |`);
  lines.push(`| Evidence commit date | ${s.timestamp} |`);
  lines.push(`| Machine | \`${s.machine}\` |`);
  lines.push(
    `| Working tree (excl. STATUS.md) | ${s.dirty ? "dirty" : "clean"} |`
  );
  lines.push(`| Generator | \`tools/status_report.ts\` |`);
  // Note: tip HEAD is intentionally omitted — it moves on every STATUS-only
  // commit and would break same-revision idempotence of the checked-in file.
  lines.push("");
  lines.push("## Commands (evidence producers)");
  lines.push("");
  for (const c of commands) lines.push(`- \`${c}\``);
  lines.push("");

  // --- Strict gate ---
  lines.push("## Strict bun gate (task-12)");
  lines.push("");
  if (strict) {
    lines.push(
      `| Field | Value |\n|-------|-------|\n| Result | **${strict.ok ? "PASS" : "FAIL"}** |\n| Summary | \`${mdEscape(strict.summary_line ?? "")}\` |\n| Observed fails | ${strict.observed_fails?.length ?? 0} |\n| Quarantined | ${strict.quarantined?.length ?? 0} |\n| Unexpected fail | ${strict.unexpected_fail?.length ?? 0} |\n| Unexpected pass | ${strict.unexpected_pass?.length ?? 0} |\n| Stale | ${strict.stale?.length ?? 0} |\n| Artifact | \`tests/artifacts/strict_bun_gate.json\` |`
    );
  } else {
    lines.push(
      "_Artifact absent_ (`tests/artifacts/strict_bun_gate.json`). Run `bun tools/testing/strict_bun_gate.ts` (or `bun run mz`) to populate."
    );
  }
  lines.push("");

  // --- Quarantine list ---
  const entries = kf.entries ?? [];
  lines.push("## Quarantine list (`tests/known_failures.json`)");
  lines.push("");
  lines.push(`Entries: **${entries.length}**`);
  lines.push("");
  if (entries.length) {
    lines.push("| ID (truncated) | Kind | Since | Reason |");
    lines.push("|---------------|------|-------|--------|");
    for (const e of entries) {
      const id =
        e.id.length > 72 ? e.id.slice(0, 69) + "…" : e.id;
      lines.push(
        `| \`${mdEscape(id)}\` | ${e.kind ?? "fail"} | ${e.since ?? "?"} | ${mdEscape((e.reason ?? "").slice(0, 120))} |`
      );
    }
    lines.push("");
  }

  // --- Parity ---
  lines.push("## Expression parity catalog");
  lines.push("");
  lines.push(
    `Inventory (source files, always current): **${inv.files}** JSON files · **${inv.cases.length}** cases under \`tests/parity/cases/\`.`
  );
  lines.push("");
  lines.push(
    "Catalog skip annotations (case declares `skip: [backend]` — not the same as a live FAIL):"
  );
  lines.push("");
  lines.push("| Backend | Catalog skips |");
  lines.push("|---------|--------------:|");
  for (const b of [...BACKENDS, STANDALONE]) {
    const n = inv.cases.filter((c) => {
      if (c.skip.includes(b)) return true;
      if (b === STANDALONE && c.skip.includes("wasm_aot")) return true;
      return false;
    }).length;
    lines.push(`| \`${b}\` | ${n} |`);
  }
  lines.push("");
  lines.push("### Live backend totals");
  lines.push("");
  const artifactIds = Object.entries(csvs).map(([b, p]) => {
    const base = path.basename(p, ".csv");
    const suffix = `_${b}`;
    const taskId = base.endsWith(suffix) ? base.slice(0, -suffix.length) : base;
    return taskId;
  });
  const uniqueTaskIds = [...new Set(artifactIds)].sort();
  lines.push(
    "When parity CSV artifacts exist under `tests/artifacts/parity/`, pass/fail/skip are from the latest run per backend. Otherwise only inventory skip counts are known (`source=inventory`). Quick runs only cover `core*.json` (small N); full runs cover the whole catalog."
  );
  if (uniqueTaskIds.length) {
    lines.push("");
    lines.push(`Latest parity artifact task id(s): \`${uniqueTaskIds.join("`, `")}\`.`);
  }
  lines.push("");
  lines.push("| Backend | Pass | Fail | Skip | Total | Source |");
  lines.push("|---------|-----:|-----:|-----:|------:|--------|");
  for (const row of backendRows) {
    const t = row.totals;
    if (t.source === "inventory") {
      lines.push(
        `| \`${row.name}\` | — | — | ${row.catalogSkip} (catalog) | ${inv.cases.length} | inventory |`
      );
    } else {
      lines.push(
        `| \`${row.name}\` | ${t.pass} | ${t.fail} | ${t.skip} | ${t.total} | artifact |`
      );
    }
  }
  lines.push("");

  // --- Standalone budget ---
  const budget = kf.standalone_skip_budget;
  lines.push("## Standalone skip budget");
  lines.push("");
  if (budget) {
    lines.push(
      `| Field | Value |\n|-------|-------|\n| max_skips | ${budget.max_skips ?? "?"} |\n| max_fails | ${budget.max_fails ?? "?"} |\n| Note | ${mdEscape(budget.note ?? "")} |`
    );
  } else {
    lines.push("_No `standalone_skip_budget` in known_failures.json._");
  }
  const sa = backendRows.find((r) => r.name === STANDALONE);
  if (sa && sa.totals.source === "artifact") {
    lines.push("");
    lines.push(
      `Latest standalone artifact: covered(pass)=${sa.totals.pass}, skipped=${sa.totals.skip}, failed=${sa.totals.fail}.`
    );
  }
  lines.push("");

  // --- MathJS ---
  lines.push("## MathJS examples (translated)");
  lines.push("");
  lines.push(
    `Translated files: **${mathjs.files}** · cases: **${mathjs.total}** (core **${mathjs.core}** / extended **${mathjs.extended}** / unsupported **${mathjs.unsupported}**; crash-hazard skips **${mathjs.crash}**).`
  );
  lines.push("");
  lines.push(
    "Core cases execute under `tests/ts/parity/mathjs_examples/run_translated.test.ts`. Failures are classified in `known_failures.json` (quarantine), not hidden."
  );
  const mathjsQ = entries.filter((e) =>
    (e.id ?? "").includes("mathjs_examples")
  );
  lines.push("");
  lines.push(
    `Quarantined MathJS core failures: **${mathjsQ.length}** (see list above). Remaining core inventory ≈ ${mathjs.core} − crash hazards; gate treats quarantined fails as allowed.`
  );
  lines.push("");

  // --- Graph corpus ---
  lines.push("## Graph corpus × runner matrix (task-13)");
  lines.push("");
  lines.push(
    `Goldens: **${graph.files.length}** files · **${graph.cases.length}** cases under \`tests/graph/goldens/\`.`
  );
  lines.push("");
  lines.push(
    "Modes: `ts_wasm` (TS GraphRunner), `native_vm` (VM-native evaluator v1), `zig_vm` (composed-expression oracle), `native_wasm` (phase-2 — expected skip)."
  );
  lines.push("");
  lines.push("| Case | Form | ts_wasm | native_vm | zig_vm | native_wasm |");
  lines.push("|------|------|---------|-----------|--------|-------------|");
  for (const row of graph.matrix) {
    lines.push(
      `| \`${row.id}\` | ${row.form} | ${row.ts_wasm} | ${row.native_vm} | ${row.zig_vm} | ${row.native_wasm} |`
    );
  }
  lines.push("");

  // --- Spec stream criterion summary ---
  lines.push("## Spec stream criterion summary");
  lines.push("");
  lines.push(
    "Strongest verified subcomponents (not blanket “plan complete”). Detail: `docs/archive/audits/AUDIT_2026-07-10.md` + `docs/guides/capabilities.md`. Live claims only here."
  );
  lines.push("");
  lines.push("| Stream | Tasks | Criterion-level state |");
  lines.push("|--------|-------|------------------------|");
  lines.push(
    "| A (AOT parity) | 01–07 | **Implemented, residual acceptance debt** — ABI JSON, delegated env, tiers, gauntlet/fuzz real; 3 residual `wasm_aot` skips (`round` decimals); standalone budget recorded; historical NaN claim closed via result_kind side-channel (task-18 D3) rather than pure hard-error everywhere. |"
  );
  lines.push(
    "| B (node graph) | 08–11 | **Implemented, residual debt** — full-Value edges, setParam/reload, browser demo, DSL lowering, VM-native graph evaluator v1 (never loads .wasm); pure-wasm node interpreter = phase-2 skip. Shared-memory deferred (measured <2×, task-19 P5). |"
  );
  lines.push(
    "| C (hardening) | 12–20 | **C1–C8 landed on base; C9 = this report** — strict gate, cross-runner corpus, adversarial, units honesty, soak, CI polish, source defects D1–D5, proof obligations P1–P5, docs truth. |"
  );
  lines.push("");

  lines.push("## How to refresh");
  lines.push("");
  lines.push("```bash");
  lines.push('export PATH="$PWD/tools/macos-sdk-shim:$PATH"');
  lines.push("bun run mz -- --quick          # or full: bun run mz");
  lines.push("bun tools/status_report.ts     # rewrite docs/STATUS.md");
  lines.push("bun tools/status_report.ts --check  # idempotence at this revision");
  lines.push("```");
  lines.push("");
  lines.push("---");
  lines.push("");
  lines.push(
    `_End of generated report. Do not hand-edit; change the generator or re-run after new artifacts._`
  );
  lines.push("");

  return lines.join("\n");
}

export function writeStatusReport(target: string = STATUS_PATH): string {
  const md = buildStatusMarkdown();
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, md);
  return md;
}

function main() {
  const args = process.argv.slice(2);
  const check = args.includes("--check");
  const stdout = args.includes("--stdout");

  const md = buildStatusMarkdown();

  if (stdout) {
    process.stdout.write(md);
    return;
  }

  if (check) {
    if (!fs.existsSync(STATUS_PATH)) {
      console.error(`Missing ${STATUS_PATH}; run without --check first.`);
      process.exit(1);
    }
    const onDisk = fs.readFileSync(STATUS_PATH, "utf8");
    if (onDisk !== md) {
      console.error(
        "docs/STATUS.md differs from regeneration (same-revision idempotence failed)."
      );
      // Show a short diff hint
      const a = onDisk.split("\n");
      const b = md.split("\n");
      for (let i = 0; i < Math.max(a.length, b.length); i++) {
        if (a[i] !== b[i]) {
          console.error(` first diff at line ${i + 1}:`);
          console.error(`  disk: ${a[i] ?? "<eof>"}`);
          console.error(`  regen: ${b[i] ?? "<eof>"}`);
          break;
        }
      }
      process.exit(1);
    }
    console.log("docs/STATUS.md matches regeneration (idempotent).");
    return;
  }

  writeStatusReport(STATUS_PATH);
  console.log(`Wrote ${path.relative(ROOT, STATUS_PATH)} (${md.length} bytes)`);
}

if (import.meta.main) {
  main();
}
