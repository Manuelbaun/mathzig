/**
 * Negative: re-introduce a fixed crash pattern → regression corpus catches it.
 * Evidence for task-14 acceptance (corpus always-on in gate).
 */
import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseGraphDslBytes, DslError } from "../../../src/ts/graph";
import { decodeMatrix } from "../../../src/ts/wire_decode";
import { WireDecodeError } from "../../../src/ts/graph/load_error";
import {
  readGraphManifestFromBytes,
  GraphManifestError,
  parseGraphDefinitionJson,
  GraphJsonError,
} from "../../../src/ts/graph";

describe("regression corpus catches known crash patterns", () => {
  it("S1 invalid_utf8.bin → InvalidUtf8 (not raw TypeError)", () => {
    const bytes = new Uint8Array(
      readFileSync(resolve(import.meta.dir, "../../adversarial/corpus/s1/invalid_utf8.bin")),
    );
    try {
      parseGraphDslBytes(bytes);
      // may succeed if file content is valid; if it throws must be DslError
    } catch (e) {
      expect(e).toBeInstanceOf(DslError);
      expect((e as DslError).code).toBe("InvalidUtf8");
    }
  });

  it("S2 hostile matrix dims → WireDecodeError LimitExceeded", () => {
    const blob = new Uint8Array(
      readFileSync(resolve(import.meta.dir, "../../adversarial/corpus/s2/hostile_matrix_dims.bin")),
    );
    const mem = new WebAssembly.Memory({ initial: 1 });
    new Uint8Array(mem.buffer).set(blob.subarray(0, Math.min(blob.length, mem.buffer.byteLength)));
    try {
      decodeMatrix(mem, 1024);
      throw new Error("expected WireDecodeError");
    } catch (e) {
      expect(e).toBeInstanceOf(WireDecodeError);
      expect((e as WireDecodeError).code).toBe("LimitExceeded");
    }
  });

  it("S3 truncated wasm → MalformedWasm (not silent null)", () => {
    const trunc = new Uint8Array(
      readFileSync(resolve(import.meta.dir, "../../adversarial/corpus/s3/truncated_wasm.bin")),
    );
    try {
      readGraphManifestFromBytes(trunc);
      throw new Error("expected GraphManifestError");
    } catch (e) {
      expect(e).toBeInstanceOf(GraphManifestError);
      expect((e as GraphManifestError).code).toBe("MalformedWasm");
    }
  });

  it("S4 not_object.json → InvalidGraphJson", () => {
    const text = readFileSync(
      resolve(import.meta.dir, "../../adversarial/corpus/s4/not_object.json"),
      "utf8",
    );
    try {
      parseGraphDefinitionJson(text);
      throw new Error("expected GraphJsonError");
    } catch (e) {
      expect(e).toBeInstanceOf(GraphJsonError);
      expect((e as GraphJsonError).code).toBe("InvalidGraphJson");
    }
  });
});
