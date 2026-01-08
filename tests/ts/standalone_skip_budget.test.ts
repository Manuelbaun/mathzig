import { describe, expect, test } from "bun:test";
import {
  evaluateStandaloneBudget,
  standaloneParticipated,
  type StandaloneSkipBudget,
  type StandaloneStats,
} from "../../tools/testing/standalone_skip_budget.ts";

const budget266: StandaloneSkipBudget = { max_skips: 266, max_fails: 0 };

describe("evaluateStandaloneBudget", () => {
  test("under budget → ok", () => {
    const stats: StandaloneStats = { covered: 300, skipped: 200, failed: 0 };
    const r = evaluateStandaloneBudget(stats, budget266);
    expect(r.ok).toBe(true);
    expect(r.over_skips).toBe(false);
    expect(r.over_fails).toBe(false);
    expect(r.summary_line).toContain("PASS");
    expect(r.summary_line).toContain("skipped=200/266");
    expect(r.summary_line).toContain("failed=0/0");
  });

  test("exactly at max_skips → ok", () => {
    const stats: StandaloneStats = { covered: 100, skipped: 266, failed: 0 };
    const r = evaluateStandaloneBudget(stats, budget266);
    expect(r.ok).toBe(true);
    expect(r.over_skips).toBe(false);
  });

  test("skipped = max_skips + 1 → fail", () => {
    const stats: StandaloneStats = { covered: 100, skipped: 267, failed: 0 };
    const r = evaluateStandaloneBudget(stats, budget266);
    expect(r.ok).toBe(false);
    expect(r.over_skips).toBe(true);
    expect(r.over_fails).toBe(false);
    expect(r.summary_line).toContain("FAIL");
    expect(r.summary_line).toContain("over_skips(+1)");
  });

  test("failed = 1 with max_fails: 0 → fail", () => {
    const stats: StandaloneStats = { covered: 300, skipped: 10, failed: 1 };
    const r = evaluateStandaloneBudget(stats, budget266);
    expect(r.ok).toBe(false);
    expect(r.over_fails).toBe(true);
    expect(r.over_skips).toBe(false);
    expect(r.summary_line).toContain("over_fails(+1)");
  });

  test("both over skips and fails → both flags", () => {
    const stats: StandaloneStats = { covered: 1, skipped: 300, failed: 2 };
    const r = evaluateStandaloneBudget(stats, { max_skips: 266, max_fails: 0 });
    expect(r.ok).toBe(false);
    expect(r.over_skips).toBe(true);
    expect(r.over_fails).toBe(true);
  });

  test("edge max_skips: 0 — any skip fails", () => {
    const zero: StandaloneSkipBudget = { max_skips: 0, max_fails: 0 };
    const r0 = evaluateStandaloneBudget(
      { covered: 50, skipped: 0, failed: 0 },
      zero
    );
    expect(r0.ok).toBe(true);

    const r1 = evaluateStandaloneBudget(
      { covered: 50, skipped: 1, failed: 0 },
      zero
    );
    expect(r1.ok).toBe(false);
    expect(r1.over_skips).toBe(true);
  });

  test("max_fails allows budgeted failures", () => {
    const b: StandaloneSkipBudget = { max_skips: 10, max_fails: 1 };
    expect(
      evaluateStandaloneBudget({ covered: 1, skipped: 0, failed: 1 }, b).ok
    ).toBe(true);
    expect(
      evaluateStandaloneBudget({ covered: 1, skipped: 0, failed: 2 }, b).ok
    ).toBe(false);
  });

  test("does not mutate inputs", () => {
    const stats: StandaloneStats = { covered: 1, skipped: 2, failed: 0 };
    const budget: StandaloneSkipBudget = { max_skips: 5, max_fails: 0, note: "x" };
    const r = evaluateStandaloneBudget(stats, budget);
    expect(stats).toEqual({ covered: 1, skipped: 2, failed: 0 });
    expect(budget).toEqual({ max_skips: 5, max_fails: 0, note: "x" });
    expect(r.stats).toEqual(stats);
    expect(r.stats).not.toBe(stats);
  });
});

describe("standaloneParticipated", () => {
  test("null/undefined → false", () => {
    expect(standaloneParticipated(null)).toBe(false);
    expect(standaloneParticipated(undefined)).toBe(false);
  });

  test("all zeros → false", () => {
    expect(standaloneParticipated({ covered: 0, skipped: 0, failed: 0 })).toBe(
      false
    );
  });

  test("any nonzero → true", () => {
    expect(standaloneParticipated({ covered: 1, skipped: 0, failed: 0 })).toBe(
      true
    );
    expect(standaloneParticipated({ covered: 0, skipped: 1, failed: 0 })).toBe(
      true
    );
    expect(standaloneParticipated({ covered: 0, skipped: 0, failed: 1 })).toBe(
      true
    );
  });
});
