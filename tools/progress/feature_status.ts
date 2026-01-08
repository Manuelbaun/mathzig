/**
 * Feature × backend status decision table (design §C.5 / C.5.1).
 *
 * Pure functions only — no I/O. CSV maps and case defs are supplied by the caller.
 */

export type FeatureStatus =
  | "done"
  | "partial"
  | "missing"
  | "skipped"
  | "broken"
  | "n/a"
  | "unknown";

export type CaseStatus = "pass" | "fail" | "skip";

export type EvidenceSource =
  | "manual_sticky"
  | "manual_default"
  | "not_executed"
  | "parity_csv"
  | "case_skip_all"
  | "case_skip"
  | "missing_csv"
  | "no_csv"
  | "no_cases";

export type CaseRef = {
  id: string;
  /** Backends listed in the parity case `skip` array. */
  skip?: string[];
};

/** Sticky manuals that always win (even against CSV). */
export const STICKY_MANUALS = new Set<FeatureStatus>(["n/a", "missing", "skipped"]);

/** Manual defaults allowed only when no cases match (no CSV path). */
export const MANUAL_DEFAULTS = new Set<FeatureStatus>(["done", "partial"]);

export type DecideStatusInput = {
  backend: string;
  backendsExecuted: readonly string[];
  /** Optional catalog `manual[backend]` override. */
  manual?: FeatureStatus | string | null;
  /** Matched case definitions for this feature. */
  cases: readonly CaseRef[];
  /**
   * CSV rows for this backend keyed by case id, lowercased status.
   * - `null` / omitted means CSV file not available.
   * - Only pass a Map when `backend ∈ backendsExecuted` (caller must enforce).
   */
  csvById?: ReadonlyMap<string, CaseStatus> | null;
};

export type DecideStatusResult = {
  status: FeatureStatus;
  pass: number;
  fail: number;
  skip: number;
  evidence: EvidenceSource;
  case_ids: string[];
  /** Optional warning when sticky manual contradicts CSV. */
  warning?: string;
};

/**
 * C.5.1 runtime decision table over pass/fail/skip counts.
 * `runnable = pass + fail` (excludes skip).
 */
export function applyDecisionTable(
  pass: number,
  fail: number,
  skip: number
): FeatureStatus {
  const runnable = pass + fail;
  if (fail === 0 && pass === runnable && runnable > 0 && skip === 0) return "done";
  if (fail === 0 && pass === runnable && runnable > 0 && skip > 0) return "partial";
  if (fail > 0 && pass === 0) return "broken";
  if (fail > 0 && pass > 0) {
    return fail / runnable <= 0.25 ? "partial" : "broken";
  }
  if (runnable === 0 && skip > 0) return "skipped";
  // no matched rows
  return "unknown";
}

function asStatus(raw: string | null | undefined): FeatureStatus | null {
  if (raw == null || raw === "") return null;
  const s = raw as FeatureStatus;
  const allowed: FeatureStatus[] = [
    "done",
    "partial",
    "missing",
    "skipped",
    "broken",
    "n/a",
    "unknown",
  ];
  return allowed.includes(s) ? s : null;
}

function caseSkippedOn(c: CaseRef, backend: string): boolean {
  return (c.skip ?? []).includes(backend);
}

/**
 * Count pass/fail/skip for matched cases against a CSV map.
 * Case-def skips count as skip. IDs missing from CSV are ignored (not counted).
 * Returns foundAny=false when nothing contributed to counts.
 */
export function countCaseOutcomes(
  backend: string,
  cases: readonly CaseRef[],
  csvById: ReadonlyMap<string, CaseStatus>
): { pass: number; fail: number; skip: number; foundAny: boolean; case_ids: string[] } {
  let pass = 0;
  let fail = 0;
  let skip = 0;
  let foundAny = false;
  const case_ids: string[] = [];

  for (const c of cases) {
    case_ids.push(c.id);
    if (caseSkippedOn(c, backend)) {
      skip += 1;
      foundAny = true;
      continue;
    }
    const st = csvById.get(c.id);
    if (st == null) continue;
    foundAny = true;
    if (st === "pass") pass += 1;
    else if (st === "fail") fail += 1;
    else skip += 1;
  }

  return { pass, fail, skip, foundAny, case_ids };
}

function stickyCsvWarning(
  backend: string,
  manual: FeatureStatus,
  cases: readonly CaseRef[],
  csvById: ReadonlyMap<string, CaseStatus> | null | undefined
): string | undefined {
  if (!csvById || csvById.size === 0) return undefined;
  const { pass, fail, foundAny } = countCaseOutcomes(backend, cases, csvById);
  if (!foundAny) return undefined;
  if (pass > 0 || fail > 0) {
    return `sticky manual ${manual} on ${backend} but CSV has pass=${pass} fail=${fail}`;
  }
  return undefined;
}

/**
 * Normative status derivation for one feature × backend cell (§C.5).
 *
 * Hard rule: when B ∉ backends_executed, never use CSV — sticky manual or unknown.
 */
export function decideFeatureStatus(input: DecideStatusInput): DecideStatusResult {
  const { backend, backendsExecuted, cases } = input;
  const manual = asStatus(input.manual ?? null);
  const case_ids = cases.map((c) => c.id);
  const emptyCounts = { pass: 0, fail: 0, skip: 0, case_ids };

  // --- not executed: never read CSV ---
  if (!backendsExecuted.includes(backend)) {
    if (manual && STICKY_MANUALS.has(manual)) {
      return { status: manual, ...emptyCounts, evidence: "manual_sticky" };
    }
    return { status: "unknown", ...emptyCounts, evidence: "not_executed" };
  }

  // --- sticky manuals always win when executed ---
  if (manual && STICKY_MANUALS.has(manual)) {
    const warning = stickyCsvWarning(backend, manual, cases, input.csvById);
    return {
      status: manual,
      ...emptyCounts,
      evidence: "manual_sticky",
      ...(warning ? { warning } : {}),
    };
  }

  // --- no matched cases ---
  if (cases.length === 0) {
    if (manual && MANUAL_DEFAULTS.has(manual)) {
      return { status: manual, ...emptyCounts, evidence: "manual_default" };
    }
    return { status: "unknown", ...emptyCounts, evidence: "no_cases" };
  }

  // --- all cases skip this backend (from case defs) ---
  if (cases.every((c) => caseSkippedOn(c, backend))) {
    return {
      status: "skipped",
      pass: 0,
      fail: 0,
      skip: cases.length,
      evidence: "case_skip_all",
      case_ids,
    };
  }

  // --- CSV available ---
  if (input.csvById != null) {
    const { pass, fail, skip, foundAny, case_ids: ids } = countCaseOutcomes(
      backend,
      cases,
      input.csvById
    );
    if (!foundAny) {
      return {
        status: "unknown",
        pass: 0,
        fail: 0,
        skip: 0,
        evidence: "parity_csv",
        case_ids: ids,
      };
    }
    const status = applyDecisionTable(pass, fail, skip);
    return { status, pass, fail, skip, evidence: "parity_csv", case_ids: ids };
  }

  // --- executed claimed but CSV missing ---
  // (all-case-def-skip already returned case_skip_all above)
  if (manual && MANUAL_DEFAULTS.has(manual)) {
    return { status: "unknown", ...emptyCounts, evidence: "missing_csv" };
  }

  return { status: "unknown", ...emptyCounts, evidence: "no_csv" };
}

/** Empty histogram bucket for one backend. */
export function emptyStatusHistogram(): Record<FeatureStatus, number> {
  return {
    done: 0,
    partial: 0,
    broken: 0,
    skipped: 0,
    missing: 0,
    "n/a": 0,
    unknown: 0,
  };
}
