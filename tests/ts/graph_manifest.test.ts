/**
 * Spec 01 — `mathzig:graph` manifest read + validation path.
 * Section write lives in Zig (`src/wasm/graph_manifest.zig`).
 */
import { describe, expect, it } from "bun:test";
import {
  GRAPH_MANIFEST_SECTION,
  GraphManifestError,
  readGraphManifest,
  validateGraphManifest,
  type GraphManifest,
} from "../../src/ts/graph";

function encodeLeb128(n: number): number[] {
  const bytes: number[] = [];
  let value = n >>> 0;
  do {
    let b = value & 0x7f;
    value >>>= 7;
    if (value !== 0) b |= 0x80;
    bytes.push(b);
  } while (value !== 0);
  return bytes;
}

/** Minimal valid wasm module with a single custom section. */
function wasmWithCustomSection(name: string, content: string): Uint8Array {
  const enc = new TextEncoder();
  const nameBytes = enc.encode(name);
  const contentBytes = enc.encode(content);
  const payload = [...encodeLeb128(nameBytes.length), ...nameBytes, ...contentBytes];
  const section = [0, ...encodeLeb128(payload.length), ...payload];
  return new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, ...section]);
}

const fixtureJson: GraphManifest = {
  abi: 1,
  entry: "tick",
  inputs: [{ name: "x", kind: "number" }],
  params: [{ name: "gain.k", kind: "number", default: 1.0 }],
  outputs: [
    { name: "u", kind: "number", result_tag: "number" },
    { name: "v", kind: "number", result_tag: "number" },
  ],
  out_mode: "table",
  exports: [{ name: "tick", params: 2 }],
};

describe("readGraphManifest", () => {
  it("returns null when mathzig:graph section is missing", async () => {
    const bare = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
    const module = await WebAssembly.compile(bare);
    expect(readGraphManifest(module)).toBeNull();
  });

  it("returns null for mathzig:node modules (wrong section)", async () => {
    const bytes = wasmWithCustomSection(
      "mathzig:node",
      JSON.stringify({
        abi: 1,
        name: "gain",
        inputs: [],
        params: [],
        output: { kind: "number", result_tag: "number" },
      }),
    );
    const module = await WebAssembly.compile(bytes);
    expect(readGraphManifest(module)).toBeNull();
  });

  it("parses mathzig:graph section written as fixture JSON", async () => {
    const bytes = wasmWithCustomSection(GRAPH_MANIFEST_SECTION, JSON.stringify(fixtureJson));
    const module = await WebAssembly.compile(bytes);
    const m = readGraphManifest(module);
    expect(m).not.toBeNull();
    expect(m!.abi).toBe(1);
    expect(m!.entry).toBe("tick");
    expect(m!.inputs).toEqual([{ name: "x", kind: "number" }]);
    expect(m!.params[0].name).toBe("gain.k");
    expect(m!.params[0].default).toBe(1.0);
    expect(m!.outputs).toHaveLength(2);
    expect(m!.outputs[0].name).toBe("u");
    expect(m!.outputs[1].result_tag).toBe("number");
    expect(m!.out_mode).toBe("table");
    expect(m!.exports).toEqual([{ name: "tick", params: 2 }]);
  });

  it("parses named_exports out_mode with export fields", async () => {
    const json: GraphManifest = {
      abi: 1,
      entry: "tick",
      inputs: [],
      params: [],
      outputs: [
        { name: "u", kind: "number", result_tag: "number", export: "out_u" },
        { name: "v", kind: "matrix", result_tag: "matrix", export: "out_v" },
      ],
      out_mode: "named_exports",
      exports: [
        { name: "out_u", params: 1 },
        { name: "out_v", params: 1 },
      ],
    };
    const bytes = wasmWithCustomSection(GRAPH_MANIFEST_SECTION, JSON.stringify(json));
    const module = await WebAssembly.compile(bytes);
    const m = readGraphManifest(module);
    expect(m!.out_mode).toBe("named_exports");
    expect(m!.outputs[0].export).toBe("out_u");
    expect(m!.outputs[1].kind).toBe("matrix");
  });

  it("throws on empty outputs in section payload (T5)", async () => {
    const bad = { ...fixtureJson, outputs: [] as GraphManifest["outputs"] };
    const bytes = wasmWithCustomSection(GRAPH_MANIFEST_SECTION, JSON.stringify(bad));
    const module = await WebAssembly.compile(bytes);
    expect(() => readGraphManifest(module)).toThrow(GraphManifestError);
  });
});

describe("validateGraphManifest (T5)", () => {
  it("accepts fixture", () => {
    const m = validateGraphManifest(fixtureJson);
    expect(m.outputs).toHaveLength(2);
    expect(m.out_mode).toBe("table");
  });

  it("rejects empty outputs", () => {
    expect(() => validateGraphManifest({ ...fixtureJson, outputs: [] })).toThrow(
      /outputs must be non-empty/,
    );
  });

  it("rejects unknown kind as GraphManifestError", () => {
    let caught: unknown;
    try {
      validateGraphManifest({
        ...fixtureJson,
        outputs: [{ name: "y", kind: "not_a_kind" }],
      });
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(GraphManifestError);
    expect(String((caught as Error).message)).toMatch(/Unknown port kind/);
  });

  it("rejects invalid out_mode", () => {
    expect(() =>
      validateGraphManifest({
        ...fixtureJson,
        out_mode: "magic" as GraphManifest["out_mode"],
      }),
    ).toThrow(/out_mode/);
  });
});
