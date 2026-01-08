import { describe, expect, it } from "bun:test";
import { createDefaultWasmImports, runMathZigCompiler } from "./wasm_utils";
import { AotHostEnv, readAbiManifest } from "../../src/ts/aot_env";

/**
 * Compile a module that exports linear memory + alloc, then bind the host.
 * Default expression is a matrix so the AOT compiler always emits memory/alloc
 * (pure scalars may omit both).
 */
async function attachCompiledModule(
  host: AotHostEnv,
  expr = "[1, 2; 3, 4]",
): Promise<{
  instance: WebAssembly.Instance;
  alloc: (n: number) => number;
  memory: WebAssembly.Memory;
}> {
  const wasmBytes = await runMathZigCompiler(expr, 0);
  const module = await WebAssembly.compile(wasmBytes);
  const manifest = readAbiManifest(module);
  const instance = await WebAssembly.instantiate(module, {
    env: host.buildEnvForManifest(manifest),
  });
  const exports = instance.exports as {
    memory?: WebAssembly.Memory;
    alloc?: (n: number) => number;
  };
  const memory = exports.memory;
  if (!memory) throw new Error("compiled module has no memory export");
  const alloc = exports.alloc;
  if (typeof alloc !== "function") throw new Error("compiled module has no alloc export");
  host.attachMemory(memory);
  host.attachInstance(instance.exports as Record<string, unknown>);
  return { instance, alloc, memory };
}

describe("AotHostEnv marshal kernel", () => {
  it("round-trips matrix layout via module alloc", async () => {
    const wasmBytes = await runMathZigCompiler("[1, 2; 3, 4]", 0);
    const module = await WebAssembly.compile(wasmBytes);
    const manifest = readAbiManifest(module);
    const host = new AotHostEnv();
    const instance = await WebAssembly.instantiate(module, {
      env: host.buildEnvForManifest(manifest),
    });
    host.attachMemory((instance.exports as { memory?: WebAssembly.Memory }).memory ?? null);
    host.attachInstance(instance.exports as Record<string, unknown>);
    const alloc = instance.exports.alloc as (n: number) => number;
    expect(typeof alloc).toBe("function");
    const rows = 2;
    const cols = 2;
    const ptr = alloc(8 + rows * cols * 8);
    const dv = new DataView(instance.exports.memory!.buffer);
    dv.setInt32(ptr, rows, true);
    dv.setInt32(ptr + 4, cols, true);
    const values = [1, 2, 3, 4];
    for (let i = 0; i < values.length; i++) dv.setFloat64(ptr + 8 + i * 8, values[i]!, true);
    const m = host.readMatrix(ptr);
    expect(m).not.toBeNull();
    expect(m!.rows).toBe(rows);
    expect(m!.cols).toBe(cols);
    expect(Array.from(m!.data)).toEqual(values);
  });

  it("decodes complex and predicate wire layouts", async () => {
    const host = new AotHostEnv();
    const { memory } = await attachCompiledModule(host);
    const cptr = host.writeComplex(3, -4);
    const c = host.readComplex(cptr);
    expect(c).toEqual({ re: 3, im: -4 });

    const predPtr = host.hostAlloc(24, 4);
    const dv = new DataView(memory.buffer);
    dv.setUint32(predPtr, 2, true); // gt
    dv.setUint32(predPtr + 4, 1, true); // value field
    dv.setFloat64(predPtr + 8, 5, true);
    dv.setInt32(predPtr + 16, -1, true);
    dv.setInt32(predPtr + 20, -1, true);
    const copied = host.copyPredicateTree(predPtr);
    expect(copied).toBeGreaterThan(0);
  });

  it("round-trips record layout with entry value kinds", async () => {
    const host = new AotHostEnv();
    await attachCompiledModule(host);
    const ptr = host.writeWasmRecord([
      { key: "rows", wire: 2, kind: 0 },
      { key: "cols", wire: 3, kind: 0 },
    ]);
    const entries = host.readWasmRecord(ptr);
    expect(entries).not.toBeNull();
    expect(entries!.map((e) => [e.key, e.wire, e.kind])).toEqual([
      ["rows", 2, 0],
      ["cols", 3, 0],
    ]);
  });

  it("rejects matrix layouts when probing for records (pad word != 0)", async () => {
    const host = new AotHostEnv();
    await attachCompiledModule(host);
    const mptr = host.writeMatrix(2, 2, [1, 2, 3, 4]);
    expect(host.readWasmRecord(mptr)).toBeNull();
    expect(host.readMatrix(mptr)).not.toBeNull();
  });

  it("writes and reads NUL-terminated strings in module memory", async () => {
    const host = new AotHostEnv();
    await attachCompiledModule(host);
    const off = host.writeCString("forward");
    expect(off).toBeGreaterThan(0);
    expect(host.readCString(off)).toBe("forward");
  });

  it("hard-errors when memory is attached but module alloc is missing", () => {
    const host = new AotHostEnv();
    host.attachMemory(new WebAssembly.Memory({ initial: 1 }));
    expect(() => host.writeMatrix(1, 1, [1])).toThrow(/module alloc is missing/);
  });

  it("delegates string args typed via the manifest string table", async () => {
    // std([...], "biased"): "biased" travels as a data-segment offset that the
    // host must recognize as a string (not a fill value) via manifest.strings.
    const wasmBytes = await runMathZigCompiler('std([1, 2, 3], "biased")', 0);
    const module = await WebAssembly.compile(wasmBytes);
    const manifest = readAbiManifest(module);
    expect(manifest?.strings).toBeDefined();
    const host = new AotHostEnv();
    const instance = await WebAssembly.instantiate(module, {
      env: host.buildEnvForManifest(manifest),
    });
    host.attachMemory((instance.exports as { memory?: WebAssembly.Memory }).memory ?? null);
    host.attachInstance(instance.exports as Record<string, unknown>);
    const result = (instance.exports.eval as () => number)();
    expect(result).toBeCloseTo(0.816496580927726, 12);
  });

  it("copies delegated record results into module memory (rec_get readable)", async () => {
    const wasmBytes = await runMathZigCompiler("size([1, 2, 3]).rows", 0);
    const module = await WebAssembly.compile(wasmBytes);
    const manifest = readAbiManifest(module);
    const host = new AotHostEnv();
    const instance = await WebAssembly.instantiate(module, {
      env: host.buildEnvForManifest(manifest),
    });
    host.attachMemory((instance.exports as { memory?: WebAssembly.Memory }).memory ?? null);
    host.attachInstance(instance.exports as Record<string, unknown>);
    expect((instance.exports.eval as () => number)()).toBe(1);
  });
});

describe("AotHostEnv single allocation domain (D1)", () => {
  it("host-written values survive interleaved module alloc pressure", async () => {
    // Matrix-producing module so eval() also allocates on the module heap.
    const host = new AotHostEnv();
    const { alloc, instance } = await attachCompiledModule(host, "[1, 2; 3, 4]");

    const mPtr = host.writeMatrix(2, 2, [10, 20, 30, 40]);
    const cPtr = host.writeComplex(1.5, -2.5);
    const rPtr = host.writeWasmRecord([
      { key: "a", wire: 7, kind: 0 },
      { key: "b", wire: 8, kind: 0 },
    ]);
    const sPtr = host.writeLengthPrefixedString("host-durable");
    const seriesPtr = host.writeLinearSeries([100, 200, 300], [1, 2, 3]);
    const cstrPtr = host.writeCString("key-cstr");

    // Allocate enough module-side bytes that an old end-of-memory host bump
    // (starting at initial buffer end, growing down-toward / meeting heap_ptr)
    // would collide with early host writes. Volume >> one wasm page.
    const page = 64 * 1024;
    let total = 0;
    const junk: number[] = [];
    while (total < page * 3) {
      const chunk = 4096;
      junk.push(alloc(chunk));
      total += chunk;
    }
    // Also run in-module code that allocates (matrix literal / eval).
    const evalPtr = (instance.exports.eval as () => number)();
    expect(host.readMatrix(evalPtr)).not.toBeNull();

    // Re-read every host write — values must be intact under single domain.
    const m = host.readMatrix(mPtr);
    expect(m).not.toBeNull();
    expect(Array.from(m!.data)).toEqual([10, 20, 30, 40]);

    expect(host.readComplex(cPtr)).toEqual({ re: 1.5, im: -2.5 });

    const rec = host.readWasmRecord(rPtr);
    expect(rec).not.toBeNull();
    expect(rec!.map((e) => [e.key, e.wire])).toEqual([
      ["a", 7],
      ["b", 8],
    ]);

    expect(host.readLengthPrefixedString(sPtr)).toBe("host-durable");
    expect(host.readCString(cstrPtr)).toBe("key-cstr");

    const series = host.readLinearSeries(seriesPtr);
    expect(series).not.toBeNull();
    expect(series!.timestamps).toEqual([100, 200, 300]);
    expect(series!.values).toEqual([1, 2, 3]);

    // Sanity: module alloc pointers are real and increasing-ish in the heap.
    expect(junk.length).toBeGreaterThan(0);
    expect(junk[0]).toBeGreaterThan(0);
  });

  it("attachInstance(null) clears module alloc", async () => {
    const host = new AotHostEnv();
    await attachCompiledModule(host);
    host.writeMatrix(1, 1, [1]); // works with alloc attached
    host.attachInstance(null);
    expect(() => host.writeMatrix(1, 1, [2])).toThrow(/module alloc is missing/);
  });
});

describe("createDefaultWasmImports", () => {
  it("re-exports generated env stubs", () => {
    const imports = createDefaultWasmImports();
    expect(typeof imports.env.sin).toBe("function");
    expect(typeof imports.env.exp).toBe("function");
  });
});
