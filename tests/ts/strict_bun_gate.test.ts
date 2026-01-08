import { describe, expect, test } from "bun:test";
import {
  evaluateGate,
  idsMatch,
  parseBunConsole,
  type KnownFailuresManifest,
} from "../../tools/testing/strict_bun_gate.ts";

describe("strict_bun_gate helpers", () => {
  test("idsMatch ignores file path when name chains equal", () => {
    const mid =
      "tests/ts/parity/integration.test.ts::Integration Tests > Edge Cases > should handle very large expressions";
    const obs = "Integration Tests > Edge Cases > should handle very large expressions";
    expect(idsMatch(mid, obs)).toBe(true);
    expect(idsMatch(mid, mid)).toBe(true);
    expect(idsMatch(mid, "other > name")).toBe(false);
  });

  test("parseBunConsole extracts fails", () => {
    const out = `
tests/ts/parity/integration.test.ts:
(pass) Integration Tests > Edge Cases > should handle NaN values [0.04ms]
(fail) Integration Tests > Edge Cases > should handle very large expressions [0.76ms]

12 tests failed:
(fail) Integration Tests > Edge Cases > should handle very large expressions [0.76ms]
`;
    const p = parseBunConsole(out);
    expect(p.fails.length).toBeGreaterThanOrEqual(1);
    expect(
      p.fails.some((f) => f.includes("should handle very large expressions"))
    ).toBe(true);
  });

  test("evaluateGate quarantines known fails and flags unexpected", () => {
    const manifest: KnownFailuresManifest = {
      schema_version: 1,
      entries: [
        {
          id: "tests/ts/foo.test.ts::suite > known fail",
          suite: "bun",
          scope: "full",
          reason: "x",
          since: "2026-07-15",
        },
      ],
    };
    const r1 = evaluateGate(manifest, ["suite > known fail"], {
      allObservedIds: ["suite > known fail", "suite > other pass"],
    });
    expect(r1.unexpected_fail).toEqual([]);
    expect(r1.quarantined.length).toBe(1);
    expect(r1.ok).toBe(true);

    const r2 = evaluateGate(manifest, ["suite > brand new fail"], {
      allObservedIds: ["suite > brand new fail", "suite > known fail"],
    });
    expect(r2.unexpected_fail.some((f) => f.includes("brand new"))).toBe(true);
    expect(r2.ok).toBe(false);

    // known fail no longer failing → unexpected pass
    const r3 = evaluateGate(manifest, [], {
      allObservedIds: ["suite > known fail", "suite > other"],
    });
    expect(r3.unexpected_pass.length).toBe(1);
    expect(r3.ok).toBe(false);
  });
});
