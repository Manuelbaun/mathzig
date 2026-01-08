import { describe, expect, it } from "bun:test";
import * as fs from "node:fs";
import aotAbi from "../../src/bindings/generated/aot_abi.json";
import {
  assertDimensionalCoverage,
  assertFullCoverage,
  checkGauntletIdempotent,
  coverageByBuiltin,
  coverageByDimension,
  generateGauntletCases,
  GAUNTLET_OUT,
  listSupportedBuiltins,
  renderGauntletJson,
  requiredDimensions,
} from "../parity/generate_gauntlet";
import { exprsForSeed, generateFuzzCorpus, mulberry32, runFuzz } from "../parity/fuzz";

describe("generated builtin gauntlet", () => {
  it("covers every supported builtin in aot_abi.json (≥1 case each)", () => {
    const cases = generateGauntletCases();
    assertFullCoverage(cases);
    const cov = coverageByBuiltin(cases);
    const supported = listSupportedBuiltins();
    expect(supported.length).toBeGreaterThan(100);
    expect(cases.length).toBeGreaterThan(supported.length);
    for (const { name } of supported) {
      expect(cov.get(name) ?? 0).toBeGreaterThan(0);
    }
  });

  it("covers required dimensions (builtin × arity × boundary-class)", () => {
    const cases = generateGauntletCases();
    assertDimensionalCoverage(cases);
    const byDim = coverageByDimension(cases);
    for (const { name, spec } of listSupportedBuiltins()) {
      const required = requiredDimensions(name, spec);
      const present = byDim.get(name) ?? new Set();
      for (const dim of required) {
        expect(present.has(dim), `${name} missing dimension ${dim}`).toBe(true);
      }
    }
  });

  it("regeneration is idempotent with checked-in generated_gauntlet.json", () => {
    const res = checkGauntletIdempotent();
    expect(res.ok).toBe(true);
    expect(res.generatedCount).toBe(res.existingCount);
    expect(res.generatedCount).toBeGreaterThan(0);
  });

  it("checked-in file is valid parity case JSON array with unique ids", () => {
    expect(fs.existsSync(GAUNTLET_OUT)).toBe(true);
    const raw = JSON.parse(fs.readFileSync(GAUNTLET_OUT, "utf8"));
    expect(Array.isArray(raw)).toBe(true);
    const ids = new Set<string>();
    for (const c of raw) {
      expect(typeof c.id).toBe("string");
      expect(typeof c.expr).toBe("string");
      expect(c.expr.length).toBeGreaterThan(0);
      expect(ids.has(c.id)).toBe(false);
      ids.add(c.id);
    }
    // Round-trip render matches file bytes
    const generated = renderGauntletJson(generateGauntletCases());
    expect(generated).toBe(fs.readFileSync(GAUNTLET_OUT, "utf8"));
  });

  it("skips only unsupported builtins from aot_abi", () => {
    const unsupported = Object.entries((aotAbi as any).builtins)
      .filter(([, s]: any) => !s.supported)
      .map(([n]) => n);
    // write_csv, create_unit, config are the known unsupported set
    expect(unsupported.length).toBeGreaterThan(0);
    const cases = generateGauntletCases();
    for (const name of unsupported) {
      const hit = cases.some((c) => c.id.startsWith(`gauntlet_${name.replace(/_+$/, "")}_`));
      // Unsupported builtins must not be required; optional presence is fine if any
      void hit;
    }
    // Explicitly: coverage map only tracks supported
    const cov = coverageByBuiltin(cases);
    for (const name of unsupported) {
      expect(cov.has(name)).toBe(false);
    }
  });
});

describe("seeded differential fuzz", () => {
  it("mulberry32 is deterministic", () => {
    const a = mulberry32(123);
    const b = mulberry32(123);
    const seqA = [a(), a(), a(), a(), a()];
    const seqB = [b(), b(), b(), b(), b()];
    expect(seqA).toEqual(seqB);
    const c = mulberry32(124);
    expect(c()).not.toBe(seqA[0]);
  });

  it("same seed → same expression corpus", () => {
    const seed = 0x4d415448;
    const e1 = exprsForSeed(seed, 50);
    const e2 = exprsForSeed(seed, 50);
    expect(e1).toEqual(e2);
    expect(e1.length).toBe(50);
    // Different seed diverges
    const e3 = exprsForSeed(seed + 1, 50);
    expect(e3).not.toEqual(e1);
  });

  it("corpus only references fuzzable builtins (no random/I/O)", () => {
    const corpus = generateFuzzCorpus(99, 100);
    const banned = ["random", "randomInt", "pickRandom", "now", "read_csv", "write_csv"];
    for (const fe of corpus) {
      expect(banned.includes(fe.builtin)).toBe(false);
      expect(fe.expr.length).toBeGreaterThan(0);
    }
  });

  /**
   * Fixed-seed default corpus inside the strict bun gate (task-19 P2).
   * Dual-error outcomes must not count as semantic passes; failed must be 0.
   * Count is modest so the gate stays practical; full 500 is CLI default.
   */
  it("default-seed corpus: no divergences; dual_error is its own bucket", async () => {
    const res = await runFuzz({ seed: 0x4d415448, count: 40, quiet: true });
    expect(res.failed).toBe(0);
    expect(res.divergences.length).toBe(0);
    // passed + dualError == count (every case classified)
    expect(res.passed + res.dualError).toBe(res.count);
    // dual errors are NOT folded into passed
    expect(res.passed).toBeLessThanOrEqual(res.count);
    expect(res.dualError).toBeGreaterThanOrEqual(0);
    // Surface the bucket for gate logs
    if (res.dualError > 0) {
      console.log(
        `fuzz dual_error bucket: ${res.dualError}/${res.count} (not counted as pass)`,
      );
    }
  }, 120_000);
});
