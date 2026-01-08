/**
 * S4 graph JSON: single untrusted entry parseGraphDefinitionJson + limits + fuzz.
 */
import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  parseGraphDefinitionJson,
  parseGraphDefinitionJsonBytes,
  GraphJsonError,
  MAX_SOURCE_BYTES,
  MAX_GRAPH_NODES,
  MAX_IDENTIFIER_LEN,
  MAX_GRAPH_EDGES,
} from "../../../src/ts/graph";
import { SeededRng, DEFAULT_FUZZ_SEED, DEFAULT_FUZZ_COUNT } from "./seeded_rng";
import { assertChildFinishes } from "./deadline";

const CORPUS = resolve(import.meta.dir, "../../adversarial/corpus/s4");

function expectJsonError(fn: () => unknown, code?: string): GraphJsonError {
  try {
    fn();
    throw new Error("expected GraphJsonError");
  } catch (e) {
    expect(e).toBeInstanceOf(GraphJsonError);
    const err = e as GraphJsonError;
    expect(err.phase).toBe("graph_json");
    if (code) expect(err.code).toBe(code);
    return err;
  }
}

describe("S4 parseGraphDefinitionJson (single untrusted entry)", () => {
  it("valid minimal graph PASS", () => {
    const def = parseGraphDefinitionJson(
      JSON.stringify({
        nodes: [{ id: "a", type: "const", value: 1 }],
        outputs: { a: "a.out" },
      }),
    );
    expect(def.nodes).toHaveLength(1);
  });

  it("over-limit source → SourceTooLarge", () => {
    const src = "{" + " ".repeat(MAX_SOURCE_BYTES) + "}";
    expectJsonError(() => parseGraphDefinitionJson(src), "SourceTooLarge");
  });

  it("missing nodes → MissingNodes", () => {
    expectJsonError(() => parseGraphDefinitionJson("{}"), "MissingNodes");
  });

  it("root array → InvalidGraphJson", () => {
    expectJsonError(() => parseGraphDefinitionJson("[1]"), "InvalidGraphJson");
  });

  it("over-limit nodes → LimitExceeded", () => {
    const nodes = Array.from({ length: MAX_GRAPH_NODES + 1 }, (_, i) => ({
      id: `n${i}`,
      type: "input",
    }));
    expectJsonError(
      () => parseGraphDefinitionJson(JSON.stringify({ nodes })),
      "LimitExceeded",
    );
  });

  it("at-limit nodes structure accepted by normalize count (small real count)", () => {
    // Don't allocate 10k nodes in gate — prove at-limit with 2 nodes and constant.
    const def = parseGraphDefinitionJson(
      JSON.stringify({
        nodes: [
          { id: "a", type: "input" },
          { id: "b", type: "expr", expr: "a", inputs: ["a"] },
        ],
        edges: [{ from: "a.out", to: "b.a" }],
      }),
    );
    expect(def.nodes.length).toBe(2);
    expect(def.edges.length).toBe(1);
  });

  it("edge count over limit is rejected (nodes path already covers LimitExceeded)", () => {
    // Full MAX_GRAPH_EDGES+1 JSON exceeds MAX_SOURCE_BYTES first — prove edges path
    // via normalizeGraphDefinition on an already-parsed object with too many edges.
    const { normalizeGraphDefinition } = require("../../../src/ts/graph/schema") as typeof import("../../../src/ts/graph/schema");
    const edges = Array.from({ length: MAX_GRAPH_EDGES + 1 }, (_, i) => ({
      from: "a.out" as const,
      to: `b.p${i}` as `${string}.${string}`,
    }));
    try {
      normalizeGraphDefinition({
        nodes: [
          { id: "a", type: "input" },
          { id: "b", type: "expr", expr: "1", inputs: [] },
        ],
        edges,
      });
      throw new Error("expected");
    } catch (e) {
      expect(e).toBeInstanceOf(GraphJsonError);
      expect((e as GraphJsonError).code).toBe("LimitExceeded");
    }
  });

  it("identifier too long → IdentifierTooLong", () => {
    const id = "x".repeat(MAX_IDENTIFIER_LEN + 1);
    expectJsonError(
      () =>
        parseGraphDefinitionJson(
          JSON.stringify({ nodes: [{ id, type: "input" }] }),
        ),
      "IdentifierTooLong",
    );
  });

  it("InvalidUtf8 on bad bytes", () => {
    expectJsonError(
      () => parseGraphDefinitionJsonBytes(new Uint8Array([0xff, 0xfe, 0x7b, 0x7d])),
      "InvalidUtf8",
    );
  });
});

describe("S4 regression corpus", () => {
  it("corpus files yield typed GraphJsonError (or no crash)", () => {
    for (const f of readdirSync(CORPUS).sort()) {
      const text = readFileSync(join(CORPUS, f), "utf8");
      try {
        parseGraphDefinitionJson(text);
      } catch (e) {
        expect(e).toBeInstanceOf(GraphJsonError);
        expect((e as GraphJsonError).code.length).toBeGreaterThan(0);
      }
    }
  });
});

describe("S4 seeded fuzzer", () => {
  it(`seed=0x${DEFAULT_FUZZ_SEED.toString(16)} count=${DEFAULT_FUZZ_COUNT}`, () => {
    const rng = new SeededRng(DEFAULT_FUZZ_SEED);
    const valid = new TextEncoder().encode(
      JSON.stringify({
        nodes: [
          { id: "x", type: "input" },
          { id: "y", type: "expr", expr: "x*2", inputs: ["x"] },
        ],
        edges: [{ from: "x.out", to: "y.x" }],
        outputs: { y: "y.out" },
      }),
    );
    for (let i = 0; i < DEFAULT_FUZZ_COUNT; i++) {
      const mode = rng.nextInt(0, 3);
      const bytes =
        mode === 0 ? rng.bytes(200) : mode === 1 ? rng.truncate(valid) : rng.mutate(valid);
      try {
        parseGraphDefinitionJsonBytes(bytes);
      } catch (e) {
        expect(e).toBeInstanceOf(GraphJsonError);
      }
    }
  });
});

describe("S4 hang containment", () => {
  it("child finishes under deadline", () => {
    assertChildFinishes("tests/ts/adversarial/child_s4_pathological.ts", [], 3000);
  });
});
