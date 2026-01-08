/**
 * S2 wire-decode adversarial: pure helpers (no native lib required).
 */
import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { WireDecodeError } from "../../../src/ts/graph/load_error";
import {
  decodeLengthPrefixedString,
  decodeMatrix,
  decodeWasmRecord,
  decodeSeriesLayout,
} from "../../../src/ts/wire_decode";
import {
  MAX_MATRIX_ELEMENTS,
  MAX_RECORD_ENTRIES,
  MAX_WIRE_STRING_BYTES,
} from "../../../src/ts/graph/limits";
import { SeededRng, DEFAULT_FUZZ_SEED, DEFAULT_FUZZ_COUNT } from "./seeded_rng";
import { assertChildFinishes } from "./deadline";

function mem(size = 4096): WebAssembly.Memory {
  return new WebAssembly.Memory({ initial: Math.max(1, Math.ceil(size / 65536)) });
}

function writeU32(m: WebAssembly.Memory, off: number, v: number) {
  new DataView(m.buffer).setUint32(off, v >>> 0, true);
}
function writeI32(m: WebAssembly.Memory, off: number, v: number) {
  new DataView(m.buffer).setInt32(off, v | 0, true);
}

describe("S2 wire decode limits (strict)", () => {
  it("string len > memory → OutOfBounds (no alloc)", () => {
    const m = mem(4096);
    writeU32(m, 128, 0xffffffff);
    try {
      decodeLengthPrefixedString(m, 128);
      throw new Error("expected throw");
    } catch (e) {
      expect(e).toBeInstanceOf(WireDecodeError);
      const err = e as WireDecodeError;
      expect(err.phase).toBe("wire");
      expect(["OutOfBounds", "LimitExceeded"]).toContain(err.code);
    }
  });

  it("string len over MAX_WIRE_STRING_BYTES → LimitExceeded", () => {
    const m = mem(256);
    writeU32(m, 16, MAX_WIRE_STRING_BYTES + 1);
    try {
      decodeLengthPrefixedString(m, 16);
      throw new Error("expected throw");
    } catch (e) {
      expect(e).toBeInstanceOf(WireDecodeError);
      expect((e as WireDecodeError).code).toBe("LimitExceeded");
    }
  });

  it("matrix huge dims → LimitExceeded pre-alloc", () => {
    const m = mem(4096);
    writeI32(m, 1024, 0x7fffffff);
    writeI32(m, 1028, 0x7fffffff);
    try {
      decodeMatrix(m, 1024);
      throw new Error("expected throw");
    } catch (e) {
      expect(e).toBeInstanceOf(WireDecodeError);
      expect((e as WireDecodeError).code).toBe("LimitExceeded");
    }
  });

  it("at-limit empty matrix PASS", () => {
    const m = mem(4096);
    writeI32(m, 1024, 0);
    writeI32(m, 1028, 0);
    const mat = decodeMatrix(m, 1024);
    expect(mat).not.toBeNull();
    expect(mat!.rows).toBe(0);
  });

  it("matrix 1x1 PASS", () => {
    const m = mem(4096);
    writeI32(m, 1024, 1);
    writeI32(m, 1028, 1);
    new DataView(m.buffer).setFloat64(1032, 3.5, true);
    const mat = decodeMatrix(m, 1024);
    expect(mat!.data[0]).toBe(3.5);
  });

  it("record count over MAX_RECORD_ENTRIES → LimitExceeded", () => {
    const m = mem(4096);
    writeU32(m, 1024, MAX_RECORD_ENTRIES + 1);
    writeU32(m, 1028, 0);
    try {
      decodeWasmRecord(m, 1024);
      throw new Error("expected throw");
    } catch (e) {
      expect(e).toBeInstanceOf(WireDecodeError);
      expect((e as WireDecodeError).code).toBe("LimitExceeded");
    }
  });

  it("series len 0xFFFFFFFF → LimitExceeded or OutOfBounds", () => {
    const m = mem(4096);
    writeU32(m, 64, 0xffffffff);
    try {
      decodeSeriesLayout(m, 64);
      throw new Error("expected throw");
    } catch (e) {
      expect(e).toBeInstanceOf(WireDecodeError);
      expect(["LimitExceeded", "OutOfBounds"]).toContain((e as WireDecodeError).code);
    }
  });

  it("soft path returns null", () => {
    const m = mem(256);
    expect(decodeMatrix(m, -1, { soft: true })).toBeNull();
    expect(decodeLengthPrefixedString(m, -1, { soft: true })).toBeNull();
    // OOB: pointer past end of buffer (memory is page-sized; use huge ptr)
    expect(decodeMatrix(m, m.buffer.byteLength - 2, { soft: true })).toBeNull();
    expect(decodeLengthPrefixedString(m, m.buffer.byteLength - 2, { soft: true })).toBeNull();
  });

  it("soft path rejects over-cap matrix without throw", () => {
    const m = mem(4096);
    writeI32(m, 1024, MAX_MATRIX_ELEMENTS + 1);
    writeI32(m, 1028, 1);
    expect(decodeMatrix(m, 1024, { soft: true })).toBeNull();
  });
});

describe("S2 regression corpus", () => {
  it("hostile corpus blobs yield WireDecodeError only", () => {
    const dir = resolve(import.meta.dir, "../../adversarial/corpus/s2");
    const matrixBlob = new Uint8Array(readFileSync(resolve(dir, "hostile_matrix_dims.bin")));
    const stringBlob = new Uint8Array(readFileSync(resolve(dir, "hostile_string_len.bin")));
    const m1 = mem(65536);
    new Uint8Array(m1.buffer).set(matrixBlob.subarray(0, Math.min(matrixBlob.length, m1.buffer.byteLength)));
    try {
      decodeMatrix(m1, 1024);
    } catch (e) {
      expect(e).toBeInstanceOf(WireDecodeError);
    }
    const m2 = mem(65536);
    new Uint8Array(m2.buffer).set(stringBlob.subarray(0, Math.min(stringBlob.length, m2.buffer.byteLength)));
    try {
      decodeLengthPrefixedString(m2, 64);
    } catch (e) {
      expect(e).toBeInstanceOf(WireDecodeError);
    }
  });
});

describe("S2 seeded fuzzer", () => {
  it(`seed=0x${DEFAULT_FUZZ_SEED.toString(16)} count=${DEFAULT_FUZZ_COUNT}`, () => {
    const rng = new SeededRng(DEFAULT_FUZZ_SEED);
    const m = mem(4096);
    for (let i = 0; i < DEFAULT_FUZZ_COUNT; i++) {
      const ptr = rng.nextInt(0, 2048);
      writeU32(m, ptr, rng.nextU32());
      writeU32(m, Math.min(ptr + 4, 4092), rng.nextU32());
      try {
        decodeMatrix(m, ptr);
      } catch (e) {
        expect(e).toBeInstanceOf(WireDecodeError);
      }
      try {
        decodeLengthPrefixedString(m, ptr);
      } catch (e) {
        expect(e).toBeInstanceOf(WireDecodeError);
      }
      try {
        decodeWasmRecord(m, ptr);
      } catch (e) {
        expect(e).toBeInstanceOf(WireDecodeError);
      }
      try {
        decodeSeriesLayout(m, ptr);
      } catch (e) {
        expect(e).toBeInstanceOf(WireDecodeError);
      }
    }
  });
});

describe("S2 hang containment", () => {
  it("hostile headers finish under deadline", () => {
    assertChildFinishes("tests/ts/adversarial/child_s2_pathological.ts", [], 3000);
  });
});
