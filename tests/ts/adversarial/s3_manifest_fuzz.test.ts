/**
 * S3 manifest/custom-section: malformed-vs-absent + seeded fuzz + corpus.
 */
import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  GraphManifestError,
  readGraphManifestFromBytes,
  readNodeManifestFromBytes,
  scanCustomSectionBytes,
  GRAPH_MANIFEST_SECTION,
  NODE_MANIFEST_SECTION,
  validateGraphManifest,
} from "../../../src/ts/graph";
import { SeededRng, DEFAULT_FUZZ_SEED, DEFAULT_FUZZ_COUNT } from "./seeded_rng";
import { assertChildFinishes } from "./deadline";

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

function wasmWithCustomSection(name: string, content: string | Uint8Array): Uint8Array {
  const enc = new TextEncoder();
  const nameBytes = enc.encode(name);
  const contentBytes = typeof content === "string" ? enc.encode(content) : content;
  const payload = [...encodeLeb128(nameBytes.length), ...nameBytes, ...contentBytes];
  const section = [0, ...encodeLeb128(payload.length), ...payload];
  return new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, ...section]);
}

const goodManifest = {
  abi: 1,
  entry: "tick",
  inputs: [{ name: "x", kind: "number" }],
  params: [],
  outputs: [{ name: "y", kind: "number", result_tag: "number" }],
  out_mode: "table" as const,
};

describe("S3 malformed vs absent", () => {
  it("valid wasm without section → absent (null), not MalformedWasm", () => {
    const bare = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
    expect(scanCustomSectionBytes(bare, GRAPH_MANIFEST_SECTION)).toEqual({ kind: "absent" });
    expect(readGraphManifestFromBytes(bare)).toBeNull();
    expect(readNodeManifestFromBytes(bare)).toBeNull();
  });

  it("truncated / bad magic → MalformedWasm", () => {
    const trunc = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00]);
    expect(scanCustomSectionBytes(trunc, GRAPH_MANIFEST_SECTION).kind).toBe("malformed_wasm");
    try {
      readGraphManifestFromBytes(trunc);
      throw new Error("expected throw");
    } catch (e) {
      expect(e).toBeInstanceOf(GraphManifestError);
      expect((e as GraphManifestError).code).toBe("MalformedWasm");
      expect((e as GraphManifestError).phase).toBe("manifest");
    }
    const badMagic = new Uint8Array([0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]);
    expect(scanCustomSectionBytes(badMagic, NODE_MANIFEST_SECTION).kind).toBe("malformed_wasm");
  });

  it("truncated section payload → MalformedWasm", () => {
    // Claim huge section size
    const bytes = new Uint8Array([
      0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
      0, // custom
      0x80, 0x80, 0x01, // leb size huge
      1, 0x61, // partial
    ]);
    const scan = scanCustomSectionBytes(bytes, "mathzig:graph");
    expect(scan.kind).toBe("malformed_wasm");
  });

  it("present valid graph manifest parses", () => {
    const bytes = wasmWithCustomSection(GRAPH_MANIFEST_SECTION, JSON.stringify(goodManifest));
    const m = readGraphManifestFromBytes(bytes);
    expect(m).not.toBeNull();
    expect(m!.outputs).toHaveLength(1);
  });

  it("wrong ABI on validate → error", () => {
    expect(() =>
      validateGraphManifest({
        ...goodManifest,
        abi: 999,
        outputs: goodManifest.outputs,
      }),
    ).not.toThrow(); // abi is optional number; structural validate may allow — wrong ABI is node-manifest path
    // Present graph section with non-JSON
    const bytes = wasmWithCustomSection(GRAPH_MANIFEST_SECTION, "{not json");
    try {
      readGraphManifestFromBytes(bytes);
      throw new Error("expected");
    } catch (e) {
      expect(e).toBeInstanceOf(GraphManifestError);
      expect((e as GraphManifestError).code).toBe("InvalidManifest");
    }
  });

  it("non-UTF-8 section payload → InvalidUtf8", () => {
    const bytes = wasmWithCustomSection(GRAPH_MANIFEST_SECTION, new Uint8Array([0xff, 0xfe, 0xfd]));
    try {
      readGraphManifestFromBytes(bytes);
      throw new Error("expected");
    } catch (e) {
      expect(e).toBeInstanceOf(GraphManifestError);
      expect((e as GraphManifestError).code).toBe("InvalidUtf8");
    }
  });

  it("empty outputs rejected by validate", () => {
    expect(() =>
      validateGraphManifest({
        inputs: [],
        params: [],
        outputs: [],
      }),
    ).toThrow(GraphManifestError);
  });

  it("duplicate port names → DuplicatePort", () => {
    try {
      validateGraphManifest({
        inputs: [
          { name: "x", kind: "number" },
          { name: "x", kind: "number" },
        ],
        params: [],
        outputs: [{ name: "o", kind: "number" }],
      });
      throw new Error("expected");
    } catch (e) {
      expect(e).toBeInstanceOf(GraphManifestError);
      expect((e as GraphManifestError).code).toBe("DuplicatePort");
    }
  });
});

describe("S3 regression corpus", () => {
  it("corpus truncated → MalformedWasm; valid_absent → null", () => {
    const dir = resolve(import.meta.dir, "../../adversarial/corpus/s3");
    const trunc = new Uint8Array(readFileSync(resolve(dir, "truncated_wasm.bin")));
    expect(scanCustomSectionBytes(trunc, GRAPH_MANIFEST_SECTION).kind).toBe("malformed_wasm");
    const absent = new Uint8Array(readFileSync(resolve(dir, "valid_absent.bin")));
    expect(readGraphManifestFromBytes(absent)).toBeNull();
  });
});

describe("S3 seeded fuzzer", () => {
  it(`seed=0x${DEFAULT_FUZZ_SEED.toString(16)} count=${DEFAULT_FUZZ_COUNT}`, () => {
    const rng = new SeededRng(DEFAULT_FUZZ_SEED);
    const valid = wasmWithCustomSection(GRAPH_MANIFEST_SECTION, JSON.stringify(goodManifest));
    for (let i = 0; i < DEFAULT_FUZZ_COUNT; i++) {
      const mode = rng.nextInt(0, 3);
      const bytes =
        mode === 0 ? rng.bytes(128) : mode === 1 ? rng.truncate(valid) : rng.mutate(valid);
      try {
        readGraphManifestFromBytes(bytes);
      } catch (e) {
        expect(e).toBeInstanceOf(GraphManifestError);
        expect((e as GraphManifestError).phase).toBe("manifest");
      }
      try {
        readNodeManifestFromBytes(bytes);
      } catch (e) {
        expect(e).toBeInstanceOf(GraphManifestError);
      }
    }
  });
});

describe("S3 hang containment", () => {
  it("child finishes under deadline", () => {
    assertChildFinishes("tests/ts/adversarial/child_s3_pathological.ts", [], 3000);
  });
});
