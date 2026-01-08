import * as fs from "node:fs";
import * as path from "node:path";
import { MathZig } from "../../../src/ts/mathzig";
import { compareNormalized, normalizeMathZig } from "./normalize";
import type {
  ExampleCase,
  ExampleRunResult,
  ExampleRunSummary,
  ExampleTier,
  TranslatedExampleFile,
  TranslatedIndex,
} from "./schema";

const ROOT = path.resolve(import.meta.dir, "../../..");
const TRANSLATED_DIR = path.join(ROOT, "tests/parity/mathjs_examples/translated");
const ARTIFACTS_DIR = path.join(ROOT, "tests/artifacts/mathjs_examples");

export function loadTranslatedFile(filePath: string): TranslatedExampleFile {
  return JSON.parse(fs.readFileSync(filePath, "utf8")) as TranslatedExampleFile;
}

export function loadTranslatedIndex(indexPath = path.join(TRANSLATED_DIR, "index.json")): TranslatedIndex {
  return JSON.parse(fs.readFileSync(indexPath, "utf8")) as TranslatedIndex;
}

export function listTranslatedJsonFiles(dir = TRANSLATED_DIR): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".json") && f !== "index.json")
    .map((f) => path.join(dir, f))
    .sort();
}

export function loadAllTranslatedFiles(dir = TRANSLATED_DIR): TranslatedExampleFile[] {
  return listTranslatedJsonFiles(dir).map((f) => loadTranslatedFile(f));
}

export function findCaseInFile(file: TranslatedExampleFile, caseId: string): ExampleCase | undefined {
  return file.cases.find((c) => c.id === caseId);
}

export function runMathZigCase(ctx: MathZig, testCase: ExampleCase): ExampleRunResult {
  const base: ExampleRunResult = {
    id: testCase.id,
    source: testCase.source,
    line: testCase.line,
    expr: testCase.expr,
    tier: testCase.tier,
    status: "ERROR",
  };

  if (testCase.hazard === "crash") {
    return { ...base, status: "FAIL", reason: "known crash hazard (dynamic record assignment)" };
  }

  try {
    for (const setupExpr of testCase.preSetup ?? []) {
      try {
        ctx.eval(setupExpr);
      } catch (e) {
        return {
          ...base,
          status: "FAIL",
          reason: `preSetup failed (${setupExpr}): ${(e as Error).message}`,
          expected: testCase.expected,
        };
      }
    }

    if (testCase.vars) {
      for (const [name, value] of Object.entries(testCase.vars)) {
        ctx.setVariable(name, value);
      }
    }

    for (const setupExpr of testCase.setup) {
      try {
        ctx.eval(setupExpr);
      } catch (e) {
        return {
          ...base,
          status: "FAIL",
          reason: `setup failed (${setupExpr}): ${(e as Error).message}`,
          expected: testCase.expected,
        };
      }
    }

    let actual: ReturnType<typeof normalizeMathZig>;
    try {
      const raw = ctx.eval(testCase.expr);
      actual = normalizeMathZig(ctx, testCase.expr, raw);
    } catch (e) {
      actual = { __error: true, message: (e as Error).message };
    }

    if (testCase.expected && typeof testCase.expected === "object" && "__error" in testCase.expected) {
      const ok = typeof actual === "object" && actual !== null && "__error" in actual;
      return {
        ...base,
        status: ok ? "PASS" : "FAIL",
        reason: ok ? undefined : `expected error, got ${JSON.stringify(actual)}`,
        expected: testCase.expected,
        actual,
      };
    }

    if (testCase.expected === undefined) {
      return { ...base, status: "SKIP", reason: "no mathjs expected value", actual };
    }

    if (testCase.compareMode === "assignment") {
      const threw = typeof actual === "object" && actual !== null && "__error" in actual;
      const ok = !threw && (actual === true || actual === null || typeof actual === "number" || typeof actual === "object");
      return {
        ...base,
        status: ok ? "PASS" : "FAIL",
        reason: ok ? undefined : `assignment failed: ${JSON.stringify(actual)}`,
        expected: testCase.expected,
        actual,
      };
    }

    const cmp = compareNormalized(testCase.expected, actual, testCase.tolerance ?? 1e-9);
    return {
      ...base,
      status: cmp.ok ? "PASS" : "FAIL",
      reason: cmp.reason,
      expected: testCase.expected,
      actual,
    };
  } catch (e) {
    return { ...base, status: "ERROR", reason: (e as Error).message, expected: testCase.expected };
  }
}

function runCaseIsolated(filePath: string, testCase: ExampleCase): ExampleRunResult {
  const worker = path.join(ROOT, "tests/parity/mathjs_examples/run_case_worker.ts");
  const proc = Bun.spawnSync(["bun", worker, filePath, testCase.id], {
    cwd: ROOT,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (proc.exitCode !== 0) {
    const stderr = proc.stderr.toString();
    return {
      id: testCase.id,
      source: testCase.source,
      line: testCase.line,
      expr: testCase.expr,
      tier: testCase.tier,
      status: "ERROR",
      reason: stderr.trim() || `worker exit ${proc.exitCode}`,
    };
  }
  return JSON.parse(proc.stdout.toString()) as ExampleRunResult;
}

export function runTranslatedFile(
  file: TranslatedExampleFile,
  opts: { tier?: ExampleTier | "all"; isolated?: boolean; filePath?: string } = {}
): ExampleRunResult[] {
  const tier = opts.tier ?? "all";
  const isolated = opts.isolated ?? false;
  const filePath = opts.filePath ?? path.join(TRANSLATED_DIR, `${file.slug}.json`);
  const cases = file.cases.filter((c) => tier === "all" || c.tier === tier);
  const results: ExampleRunResult[] = [];

  for (const testCase of cases) {
    if (testCase.tier === "unsupported") {
      results.push({
        id: testCase.id,
        source: testCase.source,
        line: testCase.line,
        expr: testCase.expr,
        tier: testCase.tier,
        status: "SKIP",
        reason: testCase.reason ?? "unsupported feature",
      });
      continue;
    }

    if (isolated) {
      results.push(runCaseIsolated(filePath, testCase));
      continue;
    }

    const ctx = MathZig.create();
    try {
      results.push(runMathZigCase(ctx, testCase));
    } finally {
      ctx.destroy();
    }
  }

  return results;
}

export function runAllTranslated(opts: {
  tier?: ExampleTier | "all";
  isolated?: boolean;
  dir?: string;
} = {}): ExampleRunSummary {
  const dir = opts.dir ?? TRANSLATED_DIR;
  const tier = opts.tier ?? "all";
  const files = loadAllTranslatedFiles(dir);
  const results: ExampleRunResult[] = [];

  for (const file of files) {
    const filePath = path.join(dir, `${file.slug}.json`);
    results.push(...runTranslatedFile(file, { tier, isolated: opts.isolated, filePath }));
  }

  return {
    generatedAt: new Date().toISOString(),
    tier,
    total: results.length,
    pass: results.filter((r) => r.status === "PASS").length,
    fail: results.filter((r) => r.status === "FAIL").length,
    skip: results.filter((r) => r.status === "SKIP").length,
    error: results.filter((r) => r.status === "ERROR").length,
    results,
  };
}

/** @deprecated Use runAllTranslated */
export function runManifest(opts: { tier?: ExampleTier | "all"; isolated?: boolean } = {}): ExampleRunSummary {
  return runAllTranslated(opts);
}

export function writeArtifacts(summary: ExampleRunSummary) {
  fs.mkdirSync(ARTIFACTS_DIR, { recursive: true });
  const stamp = summary.generatedAt.replace(/[:.]/g, "-");
  const outPath = path.join(ARTIFACTS_DIR, `run_${summary.tier}_${stamp}.json`);
  fs.writeFileSync(outPath, JSON.stringify(summary, null, 2) + "\n");
  fs.writeFileSync(
    path.join(ARTIFACTS_DIR, "summary.json"),
    JSON.stringify(
      {
        generatedAt: summary.generatedAt,
        tier: summary.tier,
        total: summary.total,
        pass: summary.pass,
        fail: summary.fail,
        skip: summary.skip,
        error: summary.error,
      },
      null,
      2
    ) + "\n"
  );

  const defects = summary.results.filter((r) => r.status === "FAIL" || r.status === "ERROR");
  const defectPath = path.join(ARTIFACTS_DIR, summary.tier === "core" ? "defects_core.json" : "defects_extended.json");
  fs.writeFileSync(defectPath, JSON.stringify(defects, null, 2) + "\n");
  return { outPath, defectPath, defects };
}