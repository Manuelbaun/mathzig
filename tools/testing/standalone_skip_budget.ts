/**
 * Standalone skip/fail budget evaluator (specs/task-12 residual).
 *
 * Pure: no I/O. Used by parity CLI after wasm_aot_standalone runs and by unit tests.
 *
 * Policy:
 *   - skipped ≤ max_skips  (ceiling; checked-in max may only shrink over time)
 *   - failed  ≤ max_fails  (normally 0)
 */

export type StandaloneStats = {
  covered: number;
  skipped: number;
  failed: number;
};

export type StandaloneSkipBudget = {
  max_skips: number;
  max_fails: number;
  note?: string;
};

export type StandaloneBudgetResult = {
  ok: boolean;
  over_skips: boolean;
  over_fails: boolean;
  stats: StandaloneStats;
  budget: StandaloneSkipBudget;
  /** Human one-liner for console / report. */
  summary_line: string;
};

/**
 * Evaluate whether standalone totals are within the checked-in budget.
 * Does not mutate budget or stats.
 */
export function evaluateStandaloneBudget(
  stats: StandaloneStats,
  budget: StandaloneSkipBudget
): StandaloneBudgetResult {
  const over_skips = stats.skipped > budget.max_skips;
  const over_fails = stats.failed > budget.max_fails;
  const ok = !over_skips && !over_fails;

  const parts: string[] = [
    `standalone_budget: ${ok ? "PASS" : "FAIL"}`,
    `covered=${stats.covered}`,
    `skipped=${stats.skipped}/${budget.max_skips}`,
    `failed=${stats.failed}/${budget.max_fails}`,
  ];
  if (over_skips) {
    parts.push(`over_skips(+${stats.skipped - budget.max_skips})`);
  }
  if (over_fails) {
    parts.push(`over_fails(+${stats.failed - budget.max_fails})`);
  }

  return {
    ok,
    over_skips,
    over_fails,
    stats: { ...stats },
    budget: { max_skips: budget.max_skips, max_fails: budget.max_fails, note: budget.note },
    summary_line: parts.join(" "),
  };
}

/**
 * True if standalone participated (any of covered/skipped/failed > 0, or
 * explicitly requested — callers may also check backend list).
 */
export function standaloneParticipated(stats: StandaloneStats | undefined | null): boolean {
  if (!stats) return false;
  return stats.covered + stats.skipped + stats.failed > 0;
}
