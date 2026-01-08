/**
 * S1 DSL adversarial: limits, UTF-8 bytes entry, seeded fuzzer, regression corpus.
 */
import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  parseGraphDsl,
  parseGraphDslBytes,
  DslError,
  MAX_SOURCE_BYTES,
  MAX_IDENTIFIER_LEN,
  MAX_NESTING_DEPTH,
} from "../../../src/ts/graph";
import { SeededRng, DEFAULT_FUZZ_SEED, DEFAULT_FUZZ_COUNT } from "./seeded_rng";
import { assertChildFinishes } from "./deadline";

const CORPUS = resolve(import.meta.dir, "../../adversarial/corpus/s1");

function expectDslError(fn: () => unknown, code?: string): DslError {
  try {
    fn();
    throw new Error("expected DslError");
  } catch (e) {
    expect(e).toBeInstanceOf(DslError);
    const err = e as DslError;
    expect(err.phase).toBe("dsl");
    if (code) expect(err.code).toBe(code);
    expect(err.position).toBeDefined();
    return err;
  }
}

describe("S1 DSL limits + typed errors", () => {
  it("at-limit source bytes PASS (MAX_SOURCE_BYTES - small graph)", () => {
    // Minimal valid program; pad with line comments under the cap (no duplicate nodes).
    const pad = "//" + "x".repeat(200) + "\n";
    let src = "";
    while (src.length + pad.length < MAX_SOURCE_BYTES - 16) src += pad;
    src += "a = 1;\n";
    expect(src.length).toBeLessThanOrEqual(MAX_SOURCE_BYTES);
    const r = parseGraphDsl(src);
    expect(r.definition.nodes.length).toBeGreaterThan(0);
  });

  it("over-limit source → SourceTooLarge", () => {
    const src = "a = 1;\n" + "x".repeat(MAX_SOURCE_BYTES);
    expectDslError(() => parseGraphDsl(src), "SourceTooLarge");
  });

  it("over-limit identifier → IdentifierTooLong", () => {
    const id = "a".repeat(MAX_IDENTIFIER_LEN + 1);
    expectDslError(() => parseGraphDsl(`${id} = 1;`), "IdentifierTooLong");
  });

  it("at-limit identifier PASS", () => {
    const id = "a".repeat(MAX_IDENTIFIER_LEN);
    const r = parseGraphDsl(`${id} = 1;`);
    expect(r.definition.nodes.some((n) => n.id === id)).toBe(true);
  });

  it("nesting over limit → NestingTooDeep", () => {
    const open = "(".repeat(MAX_NESTING_DEPTH + 2);
    expectDslError(() => parseGraphDsl(`a = ${open}1;`), "NestingTooDeep");
  });

  it("InvalidUtf8 on fatal decode of bad bytes", () => {
    const bad = new Uint8Array([0x61, 0x20, 0x3d, 0x20, 0xff, 0xfe, 0x3b]); // a = <bad>;
    expectDslError(() => parseGraphDslBytes(bad), "InvalidUtf8");
  });

  it("parseGraphDslBytes accepts valid UTF-8", () => {
    const bytes = new TextEncoder().encode("a = 1 + 2;\n");
    const r = parseGraphDslBytes(bytes);
    expect(r.inputNames.length + r.definition.nodes.length).toBeGreaterThan(0);
  });
});

describe("S1 regression corpus", () => {
  it("every corpus file yields typed error (never throws non-DslError / hang)", () => {
    const files = readdirSync(CORPUS).sort();
    expect(files.length).toBeGreaterThan(0);
    for (const f of files) {
      const path = join(CORPUS, f);
      const buf = new Uint8Array(readFileSync(path));
      try {
        if (f.endsWith(".bin")) parseGraphDslBytes(buf);
        else parseGraphDsl(new TextDecoder().decode(buf));
        // truncated_expr may or may not error depending on grammar; only assert no crash
      } catch (e) {
        expect(e).toBeInstanceOf(DslError);
        expect((e as DslError).phase).toBe("dsl");
        expect((e as DslError).code.length).toBeGreaterThan(0);
      }
    }
  });
});

describe("S1 seeded fuzzer (default corpus)", () => {
  it(`seed=0x${DEFAULT_FUZZ_SEED.toString(16)} count=${DEFAULT_FUZZ_COUNT} no crash`, () => {
    const rng = new SeededRng(DEFAULT_FUZZ_SEED);
    const valid = new TextEncoder().encode("graph { param k = 2; a = x + k; out a; }");
    for (let i = 0; i < DEFAULT_FUZZ_COUNT; i++) {
      const mode = rng.nextInt(0, 4);
      let bytes: Uint8Array;
      if (mode === 0) bytes = rng.bytes(256);
      else if (mode === 1) bytes = rng.truncate(valid);
      else if (mode === 2) bytes = rng.mutate(valid);
      else bytes = new TextEncoder().encode("a = " + "(".repeat(rng.nextInt(0, 80)) + "1;");
      try {
        parseGraphDslBytes(bytes);
      } catch (e) {
        expect(e).toBeInstanceOf(DslError);
      }
    }
  });
});

describe("S1 hang containment (worker deadline)", () => {
  it("pathological input finishes under deadline in child", () => {
    assertChildFinishes(
      "tests/ts/adversarial/child_s1_pathological.ts",
      [],
      3000,
    );
  });
});
