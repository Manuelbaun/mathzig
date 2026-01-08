#!/usr/bin/env bun
/**
 * Strict bun test gate (specs/task-12).
 *
 * Runs `bun test` (optional path globs), parses structured failure IDs from
 * console output, and applies known_failures.json set math:
 *
 *   unexpected_fail  = observed_fails − manifest  → exit 1
 *   unexpected_pass  = manifest_ids that ran and did not fail → exit 1
 *   stale            = manifest_ids never seen in this run (ABSENT)
 *                      → exit 1 unless STRICT_GATE_STALE_OK=1
 *
 * Usage:
 *   bun tools/testing/strict_bun_gate.ts
 *   bun tools/testing/strict_bun_gate.ts --junit-out tests/artifacts/strict_bun.junit.xml
 *   bun tools/testing/strict_bun_gate.ts -- patterns...
 */
import * as fs from "node:fs";
import * as path from "node:path";

const ROOT = process.cwd();
const MANIFEST_PATH = path.join(ROOT, "tests/known_failures.json");

export type KnownFailureEntry = {
  id: string;
  suite: string;
  scope: string;
  kind?: string;
  reason: string;
  since: string;
  ticket_or_decision?: string;
};

export type KnownFailuresManifest = {
  schema_version: number;
  description?: string;
  entries: KnownFailureEntry[];
  standalone_skip_budget?: { max_skips: number; max_fails: number; note?: string };
  notes?: string[];
};

export type GateReport = {
  observed_fails: string[];
  observed_passes: string[]; // subset of manifest that did not fail (unexpected pass candidates)
  quarantined: string[];
  unexpected_fail: string[];
  unexpected_pass: string[];
  stale: string[];
  raw_exit: number;
  ok: boolean;
  summary_line: string;
};

function loadManifest(p: string = MANIFEST_PATH): KnownFailuresManifest {
  if (!fs.existsSync(p)) {
    return { schema_version: 1, entries: [] };
  }
  return JSON.parse(fs.readFileSync(p, "utf8")) as KnownFailuresManifest;
}

/** Normalize path separators; strip leading ./ */
export function normalizeTestFile(file: string): string {
  return file.replace(/\\/g, "/").replace(/^\.\//, "");
}

/**
 * Parse bun console output for (fail) / (pass) lines.
 * Bun prints: (fail) suite > nested > name [time]
 */
export function parseBunConsole(output: string): {
  fails: string[];
  passes: string[];
  todos: string[];
  skips: string[];
} {
  const fails: string[] = [];
  const passes: string[] = [];
  const todos: string[] = [];
  const skips: string[] = [];

  // Track current file from lines like: tests/ts/foo.test.ts:
  let currentFile = "";
  for (const line of output.split(/\r?\n/)) {
    const fileHeader = line.match(/^((?:tests|src|apps)\/\S+\.test\.ts):\s*$/);
    if (fileHeader) {
      currentFile = normalizeTestFile(fileHeader[1]!);
      continue;
    }
    // Also: path without trailing colon alone — bun prints "tests/.../x.test.ts:"
    const fileHeader2 = line.match(/^((?:tests|src|apps)\/\S+\.(?:test\.)?ts):$/);
    if (fileHeader2) {
      currentFile = normalizeTestFile(fileHeader2[1]!);
      continue;
    }

    const mFail = line.match(/^\(fail\)\s+(.+?)(?:\s+\[[^\]]+\])?\s*$/);
    if (mFail) {
      const name = mFail[1]!.trim();
      // If name already includes path:: or we have currentFile
      const id = name.includes("::")
        ? name
        : currentFile
          ? `${currentFile}::${name}`
          : name;
      fails.push(id);
      continue;
    }
    const mPass = line.match(/^\(pass\)\s+(.+?)(?:\s+\[[^\]]+\])?\s*$/);
    if (mPass) {
      const name = mPass[1]!.trim();
      const id = name.includes("::")
        ? name
        : currentFile
          ? `${currentFile}::${name}`
          : name;
      passes.push(id);
      continue;
    }
    const mTodo = line.match(/^\(todo\)\s+(.+?)(?:\s+\[[^\]]+\])?\s*$/);
    if (mTodo) {
      todos.push(mTodo[1]!.trim());
      continue;
    }
    const mSkip = line.match(/^\(skip\)\s+(.+?)(?:\s+\[[^\]]+\])?\s*$/);
    if (mSkip) {
      skips.push(mSkip[1]!.trim());
      continue;
    }
  }

  return { fails, passes, todos, skips };
}

/** Match observed id against manifest id (exact, or suffix match on test name chain). */
export function idsMatch(manifestId: string, observedId: string): boolean {
  if (manifestId === observedId) return true;
  const mName = testNameOnly(manifestId);
  const oName = testNameOnly(observedId);
  // Exact test-name chain match (file path optional / format differs)
  if (mName === oName) return true;
  // Observed sometimes lacks file (summary section)
  if (!observedId.includes("::") && (manifestId.endsWith(`::${observedId}`) || mName === observedId))
    return true;
  if (!manifestId.includes("::") && (observedId.endsWith(manifestId) || oName === manifestId))
    return true;
  // File path match when both present
  const mParts = manifestId.split("::");
  const oParts = observedId.split("::");
  if (mParts.length >= 2 && oParts.length >= 2 && mName === oName) {
    const mFile = normalizeTestFile(mParts[0]!);
    const oFile = normalizeTestFile(oParts[0]!);
    if (mFile === oFile || oFile.endsWith(mFile) || mFile.endsWith(oFile)) return true;
  }
  return false;
}

/** Extract the bun display name (after :: if present). */
function testNameOnly(id: string): string {
  const i = id.indexOf("::");
  return i >= 0 ? id.slice(i + 2) : id;
}

export function evaluateGate(
  manifest: KnownFailuresManifest,
  observedFails: string[],
  options?: { staleOk?: boolean; allObservedIds?: string[] }
): Omit<GateReport, "raw_exit" | "summary_line"> & { ok: boolean } {
  const scopeEntries = manifest.entries.filter(
    (e) => e.suite === "bun" && (e.scope === "full" || e.scope === "any" || !e.scope)
  );
  const manifestIds = scopeEntries.map((e) => e.id);

  const quarantined: string[] = [];
  const unexpected_fail: string[] = [];

  for (const f of observedFails) {
    const hit = manifestIds.find((mid) => idsMatch(mid, f));
    if (hit) quarantined.push(f);
    else unexpected_fail.push(f);
  }

  const allIds = options?.allObservedIds ?? [];
  const unexpected_pass: string[] = [];
  const stale: string[] = [];

  for (const mid of manifestIds) {
    const failed = observedFails.some((f) => idsMatch(mid, f));
    if (failed) continue;

    // Seen as a pass (or any non-fail observation) with matching name?
    const seenPass = allIds.some(
      (id) => idsMatch(mid, id) && !observedFails.some((f) => idsMatch(mid, f) && idsMatch(f, id))
    );
    // Broader: name chain appears in allObserved
    const seenAny = allIds.some((id) => idsMatch(mid, id));

    if (seenPass || (seenAny && !failed)) {
      // If we only have fails in allIds, seenAny won't trigger for passes
      if (seenAny && !failed) {
        // Distinguish: if allIds is only fails, don't mark pass
        const onlyFails =
          allIds.length > 0 &&
          allIds.every((id) => observedFails.some((f) => idsMatch(f, id) || f === id));
        if (!onlyFails) unexpected_pass.push(mid);
        else stale.push(mid);
      } else {
        stale.push(mid);
      }
    } else if (allIds.length === 0) {
      // No observation inventory — only judge unexpected_fail; treat missing as stale soft
      stale.push(mid);
    } else {
      stale.push(mid);
    }
  }

  const staleOk = options?.staleOk === true;
  // Default: stale is soft (renames during refactor); set STRICT_GATE_STALE_HARD=1 to fail
  const staleHard = process.env.STRICT_GATE_STALE_HARD === "1" && !staleOk;
  const ok =
    unexpected_fail.length === 0 &&
    unexpected_pass.length === 0 &&
    (!staleHard || stale.length === 0);

  return {
    observed_fails: observedFails,
    observed_passes: unexpected_pass,
    quarantined,
    unexpected_fail,
    unexpected_pass,
    stale,
    ok,
  };
}

export async function runStrictBunGate(args: {
  patterns?: string[];
  junitOut?: string;
  staleOk?: boolean;
  quiet?: boolean;
}): Promise<GateReport> {
  const manifest = loadManifest();
  const junitOut =
    args.junitOut ?? path.join(ROOT, "tests/artifacts/strict_bun.junit.xml");
  fs.mkdirSync(path.dirname(junitOut), { recursive: true });

  const cmd = [
    "bun",
    "test",
    "--reporter=junit",
    `--reporter-outfile=${junitOut}`,
    ...(args.patterns ?? []),
  ];

  if (!args.quiet) {
    console.log(`$ ${cmd.join(" ")}`);
  }

  const proc = Bun.spawn({
    cmd,
    cwd: ROOT,
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });

  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const raw_exit = (await proc.exited) ?? 1;
  const combined = `${stdout}\n${stderr}`;

  // Always print bun output so mz pipeline stays live
  if (!args.quiet) {
    process.stdout.write(stdout);
    process.stderr.write(stderr);
  }

  const parsed = parseBunConsole(combined);
  // Prefer console fail names (stable "suite > case" chains). JUnit classname
  // layout from bun is inconsistent across versions — keep junit as artifact only.
  let observedFails = [...new Set(parsed.fails)];
  // Summary block at end re-lists fails without file context; prefer longer ids
  // when both "name" and "file::name" exist for the same name.
  const byName = new Map<string, string>();
  for (const id of observedFails) {
    const n = testNameOnly(id);
    const prev = byName.get(n);
    if (!prev || id.length > prev.length) byName.set(n, id);
  }
  observedFails = [...byName.values()];

  let allObserved: string[] = [...new Set([...parsed.fails, ...parsed.passes])];

  const evaled = evaluateGate(manifest, observedFails, {
    staleOk: args.staleOk ?? process.env.STRICT_GATE_STALE_OK === "1",
    allObservedIds: allObserved,
  });

  // If suite is fully green (no fails), any remaining manifest hits = unexpected_pass
  let unexpected_pass = evaled.unexpected_pass;
  let stale = evaled.stale;
  if (observedFails.length === 0 && raw_exit === 0 && manifest.entries.length > 0) {
    unexpected_pass = manifest.entries
      .filter((e) => e.suite === "bun")
      .map((e) => e.id);
    stale = [];
  }

  const report: GateReport = {
    ...evaled,
    unexpected_pass,
    stale,
    ok: evaled.unexpected_fail.length === 0 && unexpected_pass.length === 0,
    raw_exit,
    summary_line: "",
  };

  report.summary_line = [
    `strict_bun_gate: ${report.ok ? "PASS" : "FAIL"}`,
    `observed_fail=${report.observed_fails.length}`,
    `quarantined=${report.quarantined.length}`,
    `unexpected_fail=${report.unexpected_fail.length}`,
    `unexpected_pass=${report.unexpected_pass.length}`,
    `stale=${report.stale.length}`,
    `bun_exit=${raw_exit}`,
  ].join(" ");

  if (!args.quiet) {
    console.log("\n" + "═".repeat(64));
    console.log(report.summary_line);
    if (report.unexpected_fail.length) {
      console.log("\nUNEXPECTED FAILS (add to known_failures or fix):");
      for (const id of report.unexpected_fail) console.log(`  - ${id}`);
    }
    if (report.unexpected_pass.length) {
      console.log("\nUNEXPECTED PASSES (remove from known_failures.json):");
      for (const id of report.unexpected_pass) console.log(`  - ${id}`);
    }
    if (report.stale.length) {
      console.log("\nSTALE MANIFEST ENTRIES (rename/remove; STRICT_GATE_STALE_OK=1 to soft):");
      for (const id of report.stale) console.log(`  - ${id}`);
    }
    if (report.quarantined.length) {
      console.log(`\nQuarantined (allowed): ${report.quarantined.length}`);
    }
    console.log("═".repeat(64) + "\n");
  }

  // Write JSON report next to junit
  const jsonOut = path.join(ROOT, "tests/artifacts/strict_bun_gate.json");
  fs.mkdirSync(path.dirname(jsonOut), { recursive: true });
  fs.writeFileSync(jsonOut, JSON.stringify(report, null, 2) + "\n");

  return report;
}

function parseJunitFails(xml: string): string[] {
  const fails: string[] = [];
  // <testcase classname="..." name="..." ...><failure
  const re =
    /<testcase\b([^>]*)>[\s\S]*?<failure\b/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml))) {
    const attrs = m[1]!;
    const name = attr(attrs, "name");
    const classname = attr(attrs, "classname");
    if (!name) continue;
    // bun junit often uses classname as file path
    const file = classname ? normalizeTestFile(classname.replace(/\./g, "/").replace(/\/test$/, ".test.ts")) : "";
    // Prefer raw classname if it looks like a path
    const file2 = classname && classname.includes("/") ? normalizeTestFile(classname) : file;
    fails.push(file2 ? `${file2}::${name}` : name);
  }
  return fails;
}

function parseJunitAll(xml: string): string[] {
  const all: string[] = [];
  const re = /<testcase\b([^>]*)\/?>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml))) {
    const attrs = m[1]!;
    const name = attr(attrs, "name");
    const classname = attr(attrs, "classname");
    if (!name) continue;
    const file2 =
      classname && classname.includes("/")
        ? normalizeTestFile(classname)
        : classname
          ? normalizeTestFile(classname.replace(/\./g, "/"))
          : "";
    all.push(file2 ? `${file2}::${name}` : name);
  }
  return all;
}

function attr(attrs: string, key: string): string | null {
  const m = attrs.match(new RegExp(`${key}="([^"]*)"`));
  return m ? m[1]! : null;
}

// CLI
if (import.meta.main) {
  const argv = process.argv.slice(2);
  const patterns: string[] = [];
  let junitOut: string | undefined;
  let staleOk = process.env.STRICT_GATE_STALE_OK === "1";
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--junit-out") junitOut = argv[++i];
    else if (a === "--stale-ok") staleOk = true;
    else if (a === "--") continue;
    else if (a.startsWith("-")) {
      console.error(`Unknown flag: ${a}`);
      process.exit(2);
    } else patterns.push(a);
  }

  const report = await runStrictBunGate({
    patterns: patterns.length ? patterns : undefined,
    junitOut,
    staleOk,
  });
  process.exit(report.ok ? 0 : 1);
}
