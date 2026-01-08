import type { AotAbiManifest } from "./graph/compile_cache";

export type { AotAbiManifest };
import { MathZig } from "./mathzig";
import aotAbi from "../bindings/generated/aot_abi.json";
import { buildGeneratedAotStubs } from "../bindings/generated/aot_env";
import { WireDecodeError } from "./graph/load_error";
import * as wire from "./wire_decode";

export const SERIES_HANDLE_BASE = aotAbi.handle_bases.series;
export const RECORD_HANDLE_BASE = aotAbi.handle_bases.record;
export const MATRIX_HANDLE_BASE = aotAbi.handle_bases.matrix;

export { WireDecodeError };
export {
  decodeLengthPrefixedString as decodeWireString,
  decodeMatrix as decodeWireMatrix,
  decodeWasmRecord as decodeWireRecord,
  decodeSeriesLayout as decodeWireSeriesLayout,
} from "./wire_decode";

export type WasmEnvImports = Record<string, (...args: number[]) => number>;

export type SeriesData = {
  timestamps: number[];
  values: number[];
  minTs: number;
  maxTs: number;
};

export type MatrixData = {
  rows: number;
  cols: number;
  data: Float64Array;
};

type BuiltinSpec = (typeof aotAbi.builtins)[string];

type AotAbiFile = {
  handle_bases: { series: number; record: number; matrix: number };
  builtins: Record<string, BuiltinSpec & { id: number }>;
};

const ABI = aotAbi as AotAbiFile;

/** Test-only observability counters for host-mediated graph edges (task-16 / C5). */
export type AotHostDebugStats = {
  /** Live series handles in the shared host store. */
  seriesHandleCount: number;
  /** Live matrix handles (durable host ids only; not module-local ptrs). */
  matrixHandleCount: number;
  /** Live record handles in the shared host store. */
  recordHandleCount: number;
  /** High-water mark of linear-memory bytes allocated via hostAlloc this process. */
  decodeBufferHighWater: number;
  /** Bytes allocated via hostAlloc since last beginTick (if tracking). */
  decodeBufferTickBytes: number;
  /** Attached wasm memory size in pages (64KiB), or 0 if none. */
  wasmMemoryPages: number;
  /** Handles created during the current tracked tick (pre endTick GC). */
  tickCreatedCount: number;
};

/**
 * Typed alloc-failure error for host-side fault injection (task-16).
 * GraphRunner wraps this with the offending node id as {@link GraphAllocError}.
 */
export class AllocFailureError extends Error {
  readonly code = "AllocFailure" as const;
  constructor(message = "AotHostEnv: injected alloc failure") {
    super(message);
    this.name = "AllocFailureError";
  }
}

export class AotHostEnv {
  memory: WebAssembly.Memory | null = null;
  readonly seriesStore = new Map<number, SeriesData>();
  readonly recordStore = new Map<number, Map<string, number>>();
  readonly matrixStore = new Map<number, MatrixData>();
  private nextSeriesId = SERIES_HANDLE_BASE;
  private nextRecordId = RECORD_HANDLE_BASE;
  private nextMatrixId = MATRIX_HANDLE_BASE;
  /**
   * Captured module `alloc(size) -> ptr` (i32→i32, 8-byte-aligned bump).
   * All host linear-memory writes go through this single domain — never a
   * private end-of-memory bump that could overlap the module heap.
   */
  private moduleAllocFn: ((n: number) => number) | null = null;
  /**
   * Captured module `result_kind` global (i32 ValueTag). Quiet NaN on the f64
   * wire is the payload for empty results; this side-channel distinguishes
   * `undefined` / `null` from genuine math NaN (D3).
   */
  private resultKindGlobal: WebAssembly.Global | null = null;
  /** Module data-segment string constants (from the abi manifest). */
  private stringTable: Record<string, number> = {};
  /** Reverse index: known string-constant offsets, for typing `any` args. */
  private stringOffsets = new Set<number>();
  private readonly keyPtrCache = new Map<string, number>();
  private readonly predicateCopyCache = new Map<number, number>();
  readonly delegateCtx: MathZig;

  /** Remaining hostAlloc / module-alloc failures to inject (test-only). */
  private failNextAllocs = 0;
  /** Decode / hostAlloc byte high-water (process lifetime for this env). */
  private decodeBufferHighWater = 0;
  /** Bytes allocated via hostAlloc in the current tracked tick. */
  private decodeBufferTickBytes = 0;
  /** When true, createSeries/Matrix/Record record ids for endTick GC. */
  private trackingTick = false;
  /** Handles created during the current tick (series / matrix / record ids). */
  private tickCreated: number[] = [];
  /** Handles retained from previous tick outputs (kept live across ticks). */
  private retainedAcrossTick = new Set<number>();

  constructor(delegateCtx?: MathZig) {
    this.delegateCtx = delegateCtx ?? MathZig.create();
  }

  reset(): void {
    this.seriesStore.clear();
    this.recordStore.clear();
    this.matrixStore.clear();
    this.nextSeriesId = SERIES_HANDLE_BASE;
    this.nextRecordId = RECORD_HANDLE_BASE;
    this.nextMatrixId = MATRIX_HANDLE_BASE;
    this.moduleAllocFn = null;
    this.resultKindGlobal = null;
    this.instanceExports = null;
    this.keyPtrCache.clear();
    this.predicateCopyCache.clear();
    this.failNextAllocs = 0;
    this.decodeBufferHighWater = 0;
    this.decodeBufferTickBytes = 0;
    this.trackingTick = false;
    this.tickCreated = [];
    this.retainedAcrossTick.clear();
    this.delegateCtx.resetMemory?.();
  }

  /**
   * Test-only: force the next `n` hostAlloc / wrapped module-alloc calls to fail.
   * Does not modify wasm codegen — host-side wrapper only.
   */
  injectAllocFailures(n: number): void {
    this.failNextAllocs = Math.max(0, Math.floor(n));
  }

  /**
   * Begin a graph tick: track newly created durable handles for end-of-tick GC.
   * Call from GraphRunner before evaluating full-Value nodes.
   */
  beginTick(): void {
    this.trackingTick = true;
    this.tickCreated = [];
    this.decodeBufferTickBytes = 0;
  }

  /**
   * End a graph tick: release durable handles created this tick that are not
   * in `liveHandles` (typically series/matrix/record ids present in outputs).
   * Keeps handle counts flat across long-running soak ticks.
   */
  endTick(liveHandles: Iterable<number> = []): void {
    const live = new Set<number>(liveHandles);
    for (const id of this.retainedAcrossTick) live.add(id);
    for (const id of this.tickCreated) {
      if (!live.has(id)) this.releaseHandle(id);
    }
    // Retain only what callers mark live for the next tick.
    this.retainedAcrossTick = new Set(liveHandles);
    this.tickCreated = [];
    this.trackingTick = false;
  }

  /** Release a durable host handle by id (series / matrix / record ranges). */
  releaseHandle(id: number): void {
    const h = Math.trunc(id);
    if (this.seriesStore.delete(h)) return;
    if (this.matrixStore.delete(h)) return;
    if (this.recordStore.delete(h)) return;
  }

  releaseSeries(id: number): void {
    this.seriesStore.delete(Math.trunc(id));
  }

  releaseMatrix(id: number): void {
    this.matrixStore.delete(Math.trunc(id));
  }

  releaseRecord(id: number): void {
    this.recordStore.delete(Math.trunc(id));
  }

  /** Test-only observability: live store sizes + decode buffer high-water. */
  debugStats(): AotHostDebugStats {
    const pages =
      this.memory != null ? Math.floor(this.memory.buffer.byteLength / 65536) : 0;
    return {
      seriesHandleCount: this.seriesStore.size,
      matrixHandleCount: this.matrixStore.size,
      recordHandleCount: this.recordStore.size,
      decodeBufferHighWater: this.decodeBufferHighWater,
      decodeBufferTickBytes: this.decodeBufferTickBytes,
      wasmMemoryPages: pages,
      tickCreatedCount: this.tickCreated.length,
    };
  }

  private noteCreated(id: number): void {
    if (this.trackingTick) this.tickCreated.push(id);
  }

  private consumeInjectedFailure(): void {
    if (this.failNextAllocs > 0) {
      this.failNextAllocs -= 1;
      throw new AllocFailureError();
    }
  }

  private noteAllocBytes(size: number): void {
    if (size <= 0) return;
    this.decodeBufferTickBytes += size;
    if (this.decodeBufferTickBytes > this.decodeBufferHighWater) {
      this.decodeBufferHighWater = this.decodeBufferTickBytes;
    }
  }

  attachMemory(memory: WebAssembly.Memory | null): void {
    this.memory = memory;
  }

  /**
   * Point the host at a module's data-segment string table so record writes
   * (and other key-offset consumers) produce offsets `rec_get` can match.
   * Call this when switching between node instances that share one HostEnv.
   */
  useStringTable(strings: Record<string, number> | null | undefined): void {
    this.stringTable = strings ?? {};
    this.stringOffsets = new Set(Object.values(this.stringTable));
  }

  /**
   * Allocate `size` bytes in the active module's linear memory via the
   * exported `alloc` captured by `attachInstance`. Module alloc always
   * 8-aligns; over-alignment for align=1/4 is intentional and safe.
   * Throws if memory is attached but no module alloc is available (no
   * second private end-of-memory bump domain).
   */
  hostAlloc(size: number, _align = 8): number {
    const mem = this.memory;
    if (!mem || size <= 0) return 0;
    // Injected failure (test-only) — typed, recoverable on next tick.
    this.consumeInjectedFailure();
    const alloc = this.moduleAllocFn;
    if (!alloc) {
      throw new Error(
        "AotHostEnv: linear memory is attached but module alloc is missing; " +
          "call attachInstance(exports) after instantiate so host writes share the module heap",
      );
    }
    // Grow may detach memory.buffer — callers must re-read buffer after this.
    // Natural OOM (alloc returns 0) stays a soft failure for writeMatrix fallbacks;
    // injected failures throw AllocFailureError above.
    const ptr = alloc(size);
    if (ptr) this.noteAllocBytes(size);
    return ptr;
  }

  readCString(ptrF64: number): string | null {
    const mem = this.memory;
    if (!mem || !Number.isFinite(ptrF64)) return null;
    const p = Math.trunc(ptrF64);
    if (p < 0) return null;
    const buf = new Uint8Array(mem.buffer);
    let end = p;
    while (end < buf.length && buf[end] !== 0) end++;
    if (end === p) return "";
    return new TextDecoder().decode(buf.subarray(p, end));
  }

  /** Decode a length-prefixed return string: `[u32 len][utf-8 bytes]`. */
  readLengthPrefixedString(ptrF64: number): string | null {
    try {
      return this.decodeLengthPrefixedString(ptrF64, { soft: true });
    } catch {
      return null;
    }
  }

  /**
   * S2 strict wire decode: length-prefixed string.
   * Hostile `u32 len` is rejected against module memory size and
   * `MAX_WIRE_STRING_BYTES` **before** any decode allocation.
   */
  decodeLengthPrefixedString(
    ptrF64: number,
    opts: { soft?: boolean } = {},
  ): string | null {
    const mem = this.memory;
    if (!mem) {
      if (opts.soft) return null;
      throw new WireDecodeError("InvalidPointer", "wire string: missing memory", {
        context: { field: "string" },
      });
    }
    return wire.decodeLengthPrefixedString(mem, ptrF64, opts);
  }

  /** Write a length-prefixed string into module memory; returns the pointer. */
  writeLengthPrefixedString(text: string): number {
    const bytes = new TextEncoder().encode(text);
    const ptr = this.hostAlloc(4 + bytes.length, 4);
    if (!ptr) return NaN;
    const mem = this.memory!;
    const dv = new DataView(mem.buffer);
    dv.setUint32(ptr, bytes.length, true);
    new Uint8Array(mem.buffer).set(bytes, ptr + 4);
    return ptr;
  }

  readMatrix(ptrF64: number): MatrixData | null {
    try {
      return this.decodeMatrix(ptrF64, { soft: true });
    } catch {
      return null;
    }
  }

  /**
   * S2 strict wire decode: matrix header `[i32 rows][i32 cols][f64 data…]`.
   * Rejects hostile dimensions before allocating the data copy.
   */
  decodeMatrix(ptrF64: number, opts: { soft?: boolean } = {}): MatrixData | null {
    if (!Number.isFinite(ptrF64)) {
      if (opts.soft) return null;
      throw new WireDecodeError("InvalidPointer", "wire matrix: non-finite ptr", {
        context: { field: "matrix" },
      });
    }
    const p = Math.trunc(ptrF64);
    // Durable host handles only (createMatrix). Never resolve module-local
    // heap pointers via matrixStore — those addresses collide across WASM
    // instances that share one AotHostEnv (multi-node GraphRunner).
    if (p >= MATRIX_HANDLE_BASE && p < SERIES_HANDLE_BASE) {
      const stored = this.matrixStore.get(p);
      if (stored) return stored;
    }
    const mem = this.memory;
    if (!mem) {
      // No linear memory: only host handles are resolvable.
      return this.matrixStore.get(p) ?? null;
    }
    if (p >= SERIES_HANDLE_BASE || p < 1024) {
      if (opts.soft) return null;
      throw new WireDecodeError("InvalidPointer", "wire matrix: ptr outside module heap range", {
        position: { byte: p },
        context: { field: "matrix" },
      });
    }
    return wire.decodeMatrix(mem, ptrF64, opts);
  }

  writeMatrix(rows: number, cols: number, values: ArrayLike<number>): number {
    const mem = this.memory;
    if (!mem) return this.createMatrix(rows, cols, Array.from(values));
    const count = rows * cols;
    const ptr = this.hostAlloc(8 + count * 8, 8);
    if (!ptr) return this.createMatrix(rows, cols, Array.from(values));
    const dv = new DataView(mem.buffer);
    dv.setInt32(ptr, rows, true);
    dv.setInt32(ptr + 4, cols, true);
    for (let i = 0; i < count; i++) {
      dv.setFloat64(ptr + 8 + i * 8, Number(values[i] ?? NaN), true);
    }
    // Do **not** cache module-local hostAlloc pointers in matrixStore — they
    // alias across multi-module graphs. Durable identity uses createMatrix.
    return ptr;
  }

  /**
   * Parse a wasm-side record: [u32 count][u32 pad(0)] then per entry
   * [f64 value][u32 key_off][u8 value_kind + 3B pad]. The pad word at +4
   * being 0 distinguishes records from matrices (cols is never 0).
   */
  readWasmRecord(ptrF64: number): Array<{ key: string; wire: number; kind: number }> | null {
    try {
      return this.decodeWasmRecord(ptrF64, { soft: true });
    } catch {
      return null;
    }
  }

  /**
   * S2 strict wire decode: record `[u32 count][u32 pad][entries…]`.
   * Hostile count rejected against memory size and `MAX_RECORD_ENTRIES` pre-alloc.
   */
  decodeWasmRecord(
    ptrF64: number,
    opts: { soft?: boolean } = {},
  ): Array<{ key: string; wire: number; kind: number }> | null {
    const mem = this.memory;
    if (!mem || !Number.isFinite(ptrF64)) {
      if (opts.soft) return null;
      throw new WireDecodeError("InvalidPointer", "wire record: missing memory or non-finite ptr", {
        context: { field: "record" },
      });
    }
    const p = Math.trunc(ptrF64);
    if (p >= SERIES_HANDLE_BASE || p < 1024) {
      if (opts.soft) return null;
      throw new WireDecodeError("OutOfBounds", "wire record: ptr out of heap range", {
        position: { byte: p },
        context: { field: "record" },
      });
    }
    return wire.decodeWasmRecord(mem, ptrF64, opts);
  }

  /**
   * S2 strict series linear-memory layout check (header only).
   * Host-handle series are resolved via `resolveSeries`; this validates
   * Tier-4 `[u32 len][u32 pad][timestamps][values]` hostile headers.
   */
  decodeSeriesLayout(
    ptrF64: number,
    opts: { soft?: boolean } = {},
  ): { len: number } | null {
    const mem = this.memory;
    if (!mem) {
      if (opts.soft) return null;
      throw new WireDecodeError("InvalidPointer", "wire series: missing memory", {
        context: { field: "series" },
      });
    }
    return wire.decodeSeriesLayout(mem, ptrF64, opts);
  }

  /** Copy a NUL-terminated string into module memory, returning its offset. */
  writeCString(text: string): number {
    const mem = this.memory;
    if (!mem) return 0;
    const bytes = new TextEncoder().encode(text);
    const ptr = this.hostAlloc(bytes.length + 1, 1);
    if (!ptr) return 0;
    const dst = new Uint8Array(mem.buffer, ptr, bytes.length + 1);
    dst.set(bytes);
    dst[bytes.length] = 0;
    return ptr;
  }

  /**
   * Write a record into module memory in the wasm record layout. Keys are
   * resolved against the module's data-segment string table so in-module
   * rec_get (which matches by key offset) can find them; keys the module
   * never references get freshly written strings (offset-matching rec_get
   * won't hit those, but result decoding reads them fine).
   */
  writeWasmRecord(entries: Array<{ key: string; wire: number; kind: number }>): number {
    const mem = this.memory;
    if (!mem) return NaN;
    const ptr = this.hostAlloc(8 + entries.length * 16, 8);
    if (!ptr) return NaN;
    const dv = new DataView(mem.buffer);
    dv.setUint32(ptr, entries.length, true);
    dv.setUint32(ptr + 4, 0, true);
    entries.forEach((e, i) => {
      const keyOff = this.stringTable[e.key] ?? this.writeCString(e.key);
      const base = ptr + 8 + i * 16;
      // module alloc may grow memory (detaching dv's buffer) — re-view per entry
      const edv = new DataView(mem.buffer);
      edv.setFloat64(base, e.wire, true);
      edv.setUint32(base + 8, keyOff, true);
      edv.setUint8(base + 12, e.kind);
    });
    return ptr;
  }

  /** Build an engine record from a wasm-side record layout or host store. */
  private engineRecordFromWasm(ptrF64: number): number {
    const stored = this.recordStore.get(Math.trunc(ptrF64));
    const entries = stored
      ? [...stored].map(([key, wire]) => ({ key, wire, kind: 0 }))
      : this.readWasmRecord(ptrF64);
    if (!entries) return NaN;
    const backend = this.delegateCtx.backend;
    const rec = backend.call("mathzig_record_new", this.delegateCtx.handle);
    if (!rec) return NaN;
    for (const e of entries) {
      let wire = e.wire;
      let kind = e.kind;
      if (kind === 4) {
        // string value: wasm offset -> native NUL-terminated copy
        const text = this.readCString(wire) ?? "";
        const bytes = new TextEncoder().encode(text);
        const p = Number(MathZig.allocAligned(8, bytes.length + 1, backend));
        const dst = new Uint8Array(backend.toArrayBuffer(p, bytes.length + 1));
        dst.set(bytes);
        dst[bytes.length] = 0;
        wire = p;
      } else if (kind === 2) {
        wire = this.engineSeriesFromWire(wire);
      } else if (kind === 1) {
        wire = this.engineMatrixFromWire(wire);
      } else if (kind === 5) {
        wire = this.engineRecordFromWasm(wire);
      } else {
        kind = 0;
      }
      if (!Number.isFinite(wire)) return NaN;
      backend.call("mathzig_record_set_wire", this.delegateCtx.handle, rec, this.backendKeyPtr(e.key), wire, kind);
    }
    return Number(rec);
  }

  private backendKeyPtr(key: string): unknown {
    return this.delegateCtx.backend.ptr(key);
  }

  readComplex(ptrF64: number): { re: number; im: number } | null {
    const mem = this.memory;
    if (!mem || !Number.isFinite(ptrF64)) return null;
    const p = Math.trunc(ptrF64);
    if (p < 0 || p + 16 > mem.buffer.byteLength) return null;
    const dv = new DataView(mem.buffer);
    const re = dv.getFloat64(p, true);
    const im = dv.getFloat64(p + 8, true);
    if (!Number.isFinite(re) || !Number.isFinite(im)) return null;
    return { re, im };
  }

  writeComplex(re: number, im: number): number {
    const ptr = this.hostAlloc(16, 8);
    const dv = new DataView(this.memory!.buffer);
    dv.setFloat64(ptr, re, true);
    dv.setFloat64(ptr + 8, im, true);
    return ptr;
  }

  createSeries(timestamps: number[], values: number[]): number {
    this.consumeInjectedFailure();
    const len = Math.min(timestamps.length, values.length);
    const ts = timestamps.slice(0, len);
    const vals = values.slice(0, len);
    let minTs = Infinity;
    let maxTs = -Infinity;
    for (const t of ts) {
      if (t < minTs) minTs = t;
      if (t > maxTs) maxTs = t;
    }
    const id = this.nextSeriesId++;
    this.seriesStore.set(id, { timestamps: ts, values: vals, minTs, maxTs });
    this.noteCreated(id);
    return id;
  }

  createMatrix(rows: number, cols: number, values: number[]): number {
    this.consumeInjectedFailure();
    const id = this.nextMatrixId++;
    this.matrixStore.set(id, { rows, cols, data: Float64Array.from(values) });
    this.noteCreated(id);
    return id;
  }

  createRecord(entries: Map<string, number>): number {
    this.consumeInjectedFailure();
    const id = this.nextRecordId++;
    this.recordStore.set(id, entries);
    this.noteCreated(id);
    return id;
  }

  resolveSeries(handle: number): SeriesData | null {
    const h = Number.isFinite(handle) ? Math.trunc(handle) : handle;
    return this.seriesStore.get(h) ?? null;
  }

  resolveMatrix(handle: number): MatrixData | null {
    const stored = this.matrixStore.get(handle);
    if (stored) return stored;
    return this.memory ? this.readMatrix(handle) : null;
  }

  /** Copy a predicate tree from wasm memory into one native buffer for FFI. */
  copyPredicateTree(predPtr: number): number {
    const cached = this.predicateCopyCache.get(predPtr);
    if (cached !== undefined) return cached;
    const mem = this.memory;
    if (!mem || !Number.isFinite(predPtr)) return 0;
    const backend = this.delegateCtx.backend;
    const rootWasm = Math.trunc(predPtr);
    const nodes: number[] = [];
    const collect = (wasmP: number) => {
      if (wasmP < 0) return;
      nodes.push(wasmP);
      const src = new DataView(mem.buffer);
      const left = src.getInt32(wasmP + 16, true);
      const right = src.getInt32(wasmP + 20, true);
      if (left >= 0) collect(left);
      if (right >= 0) collect(right);
    };
    collect(rootWasm);
    const wasmIndex = new Map<number, number>();
    for (let i = 0; i < nodes.length; i++) wasmIndex.set(nodes[i]!, i * 24);
    const size = nodes.length * 24;
    const nativeBase = Number(MathZig.allocAligned(4, size, backend));
    const buf = new Uint8Array(backend.toArrayBuffer(nativeBase, size));
    for (let i = 0; i < nodes.length; i++) {
      const wasmP = nodes[i]!;
      const off = i * 24;
      buf.set(new Uint8Array(mem.buffer, wasmP, 16), off);
      const src = new DataView(mem.buffer);
      const out = new DataView(buf.buffer);
      const left = src.getInt32(wasmP + 16, true);
      const right = src.getInt32(wasmP + 20, true);
      out.setInt32(off + 16, left >= 0 ? wasmIndex.get(left)! : -1, true);
      out.setInt32(off + 20, right >= 0 ? wasmIndex.get(right)! : -1, true);
    }
    this.predicateCopyCache.set(predPtr, nativeBase);
    return nativeBase;
  }

  private engineMatrixFromWire(wire: number): number {
    const m = this.resolveMatrix(wire);
    if (!m) return 0;
    const backend = this.delegateCtx.backend;
    // bun:ffi refuses empty ArrayBufferViews — use a dummy 1-slot buffer when
    // the matrix has zero elements (count is still passed as 0 via rows*cols).
    const data =
      m.data.length > 0 ? m.data : new Float64Array(1);
    const dataPtr = backend.ptr(data);
    const eng = backend.call("mathzig_matrix_from_data", m.rows, m.cols, dataPtr);
    return Number(eng);
  }

  private engineSeriesFromWire(wire: number): number {
    const s = this.resolveSeries(wire);
    if (!s) return 0;
    const backend = this.delegateCtx.backend;
    const count = s.values.length;
    // bun:ffi refuses empty ArrayBufferViews — pass a dummy buffer when empty.
    // Prefer the high-level createSeries path for non-empty (ownership + mode
    // handling). Empty series go through the raw export with count=0.
    if (count === 0) {
      const dummy = new Float64Array(1);
      const eng = backend.call(
        "mathzig_create_series",
        this.delegateCtx.handle,
        backend.ptr(dummy),
        backend.ptr(dummy),
        0,
        1, // Linear
      );
      return Number(eng);
    }
    const ts = Float64Array.from(s.timestamps);
    const vals = Float64Array.from(s.values);
    const series = this.delegateCtx.createSeries(ts, vals);
    return Number((series as { handle: number }).handle ?? series);
  }

  /**
   * Resolve one wire arg to [engine value, wire kind byte]. The kind byte
   * tells the Zig side how to interpret the f64 (see aot_wire.WireArgKind):
   * 0 = plain number, 1 = engine Matrix pointer, 2 = engine Series pointer.
   * Without it, `any`-kind args are ambiguous (scalar vs pointer).
   */
  private resolveWireArg(kind: string, wire: number): [number, number] {
    switch (kind) {
      case "number":
      case "boolean":
        return [wire, 0];
      case "matrix_ptr":
        return [this.engineMatrixFromWire(wire), 1];
      case "record_ptr": {
        const rec = this.engineRecordFromWasm(wire);
        return Number.isFinite(rec) ? [rec, 5] : [wire, 0];
      }
      case "series_handle":
      case "any": {
        // A wire equal to a known data-segment string-constant offset is a
        // string arg (string offsets and heap pointers never overlap; a
        // numeric arg colliding with a string offset is the residual risk).
        if (this.stringOffsets.has(wire)) return this.resolveWireArg("string_ptr", wire);
        if (this.resolveSeries(wire)) return [this.engineSeriesFromWire(wire), 2];
        // The pad word at ptr+4 is 0 for records and >=1 (cols) for matrices,
        // so probe records first — readMatrix would misread a record header.
        const recEntries = this.readWasmRecord(wire);
        if (recEntries) {
          const rec = this.engineRecordFromWasm(wire);
          if (Number.isFinite(rec)) return [rec, 5];
        }
        if (this.resolveMatrix(wire)) return [this.engineMatrixFromWire(wire), 1];
        return [wire, 0];
      }
      case "complex_ptr": {
        // AOT constant-folds pure-real complexes (7+0i → 7). The VM accepts
        // re/im/conj on plain numbers; promote a finite non-pointer wire to
        // complex(re=wire, im=0) so delegated complex builtins stay in parity.
        let c = this.readComplex(wire);
        if (!c && Number.isFinite(wire) && (wire < 1024 || wire >= SERIES_HANDLE_BASE)) {
          c = { re: wire, im: 0 };
        }
        if (!c) return [NaN, 0];
        const p = MathZig.allocAligned(8, 16, this.delegateCtx.backend);
        const arr = new Float64Array(this.delegateCtx.backend.toArrayBuffer(p, 16));
        arr[0] = c.re;
        arr[1] = c.im;
        return [Number(p), 3];
      }
      case "string_ptr": {
        // Copy the wasm-side string into native memory; backend.ptr(string)
        // returns a Buffer object, not a stable address.
        const text = this.readCString(wire) ?? "";
        const bytes = new TextEncoder().encode(text);
        const backend = this.delegateCtx.backend;
        const p = Number(MathZig.allocAligned(8, bytes.length + 1, backend));
        const dst = new Uint8Array(backend.toArrayBuffer(p, bytes.length + 1));
        dst.set(bytes);
        dst[bytes.length] = 0;
        return [p, 4];
      }
      default:
        return [wire, 0];
    }
  }

  private encodeWireResult(spec: BuiltinSpec, wire: number): number {
    if (!Number.isFinite(wire)) return wire;
    // The engine reports what the result actually is (a variadic/`any` ret,
    // or an error, may not match the spec). Never treat the wire as a
    // pointer based on the signature alone.
    const actual = Number(this.delegateCtx.backend.call("mathzig_last_wire_kind"));
    const retOf: Record<number, string> = {
      0: "number",
      1: "matrix_ptr",
      2: "series_handle",
      3: "complex_ptr",
      4: "string_ptr",
      5: "record_ptr",
    };
    const actualRet = retOf[actual];
    if (actualRet === undefined) return NaN;
    if (actualRet === "number") return wire;
    if (spec.ret !== "any" && spec.ret !== actualRet) return NaN;
    return this.encodeEngineValue(actualRet, wire);
  }

  /** Copy one engine value (by wire kind name) out to host/module memory. */
  private encodeEngineValue(kind: string, wire: number): number {
    switch (kind) {
      case "series_handle": {
        const backend = this.delegateCtx.backend;
        const handle = wire;
        const rows = Number(backend.call("mathzig_series_len", handle));
        if (!Number.isFinite(rows) || rows < 0) return NaN;
        if (rows === 0) return this.createSeries([], []);
        const tsPtr = backend.call("mathzig_series_get_timestamps_ptr", handle);
        const valPtr = backend.call("mathzig_series_get_values_ptr", handle);
        const ts = new Float64Array(backend.toArrayBuffer(tsPtr, rows * 8));
        const vals = new Float64Array(backend.toArrayBuffer(valPtr, rows * 8));
        return this.createSeries(Array.from(ts), Array.from(vals));
      }
      case "matrix_ptr": {
        const backend = this.delegateCtx.backend;
        const rows = Number(backend.call("mathzig_matrix_rows", wire));
        const cols = Number(backend.call("mathzig_matrix_cols", wire));
        const count = rows * cols;
        if (!Number.isFinite(count) || count < 0) return NaN;
        if (count === 0) return this.writeMatrix(rows, cols, []);
        const dataPtr = backend.call("mathzig_matrix_get_data", wire);
        const data = new Float64Array(backend.toArrayBuffer(dataPtr, count * 8));
        return this.writeMatrix(rows, cols, data);
      }
      case "complex_ptr": {
        const backend = this.delegateCtx.backend;
        const buf = new Float64Array(backend.toArrayBuffer(wire, 16));
        return this.writeComplex(buf[0], buf[1]);
      }
      case "string_ptr": {
        // Engine string wires are raw pointers without length. Prefer formatting
        // the last stashed value (which includes quotes we strip) when available.
        const backend = this.delegateCtx.backend;
        let text = "";
        try {
          const buf = new Uint8Array(8192);
          const len = Number(
            backend.call("mathzig_format_last_value", this.delegateCtx.handle, buf, BigInt(buf.length)),
          );
          if (Number.isFinite(len) && len > 0) {
            text = new TextDecoder().decode(buf.subarray(0, len));
            if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
              text = text.slice(1, -1);
            }
          }
        } catch {
          // Fall through to empty/NUL-terminated read if format is unavailable.
        }
        if (!text && Number.isFinite(wire) && wire > 0) {
          try {
            text = backend.readString(wire) ?? "";
          } catch {
            text = "";
          }
        }
        return this.writeLengthPrefixedString(text);
      }
      case "record_ptr": {
        // Enumerate the engine record and copy it into the wasm record
        // layout so in-module field access (rec_get) can read it. Modules
        // that never touch linear memory (no memory export) still need a
        // host-side record handle for decodeResult.
        const backend = this.delegateCtx.backend;
        const count = Number(backend.call("mathzig_record_len", wire));
        if (!count) return NaN;
        const kindName: Record<number, string> = {
          1: "matrix_ptr",
          2: "series_handle",
          3: "complex_ptr",
          5: "record_ptr",
        };
        const entries: Array<{ key: string; wire: number; kind: number }> = [];
        for (let i = 0; i < count; i++) {
          const keyPtr = backend.call("mathzig_record_key_at", wire, i);
          if (!keyPtr) return NaN;
          const key = backend.readString(keyPtr);
          const vKind = Number(backend.call("mathzig_record_value_kind_at", wire, i));
          const vWire = Number(backend.call("mathzig_record_value_wire_at", wire, i));
          const encoded = vKind === 0 ? vWire : this.encodeEngineValue(kindName[vKind] ?? "", vWire);
          if (!Number.isFinite(encoded)) return NaN;
          entries.push({ key, wire: encoded, kind: vKind > 5 ? 0 : vKind });
        }
        if (!this.memory) {
          const map = new Map<string, number>();
          for (const e of entries) map.set(e.key, e.wire);
          return this.createRecord(map);
        }
        return this.writeWasmRecord(entries);
      }
      default:
        return wire;
    }
  }

  /**
   * Shared path for AOT env.conv / env.number when units were stripped to
   * SI magnitudes. Matrix + finite target scale → elementwise / scale.
   * Scalar + target≈1 → identity. Else delegate to native engine.
   *
   * ## Known limitation (task-15 — see mathzig.abi `unit_runtime`)
   * When the AOT module emits a non-folded dynamic unit op, the custom section
   * field `unit_runtime` is `"host_dynamic"` so hosts can refuse load instead of
   * failing on first call. Until a real unit-descriptor/handle ABI lands
   * (`docs/tasks/archive/specs/task-15-c4-units-honesty/unit_abi_proposal.md`), this path still
   * uses the **target≈1 identity workaround**: SI-base targets wire as scale 1
   * after unit stripping, so we return `source` unchanged. That loses true
   * source/target dimensions on the wire and is only safe when the compile-time
   * fold already SI-normalized the magnitude (or the host only needs SI).
   * Do not treat target≈1 as a full dimensional conversion.
   */
  private convOrNumberWire(source: number, target: number, name: "conv" | "number"): number {
    const mat = this.readMatrix(source) ?? this.resolveMatrix(source);
    if (mat && Number.isFinite(target) && target !== 0) {
      const out = new Float64Array(mat.data.length);
      for (let i = 0; i < mat.data.length; i++) {
        out[i] = mat.data[i]! / target;
      }
      return this.writeMatrix(mat.rows, mat.cols, out);
    }
    // target≈1 identity workaround (see docblock above + unit_runtime field).
    if (Number.isFinite(source) && Number.isFinite(target) && Math.abs(target - 1) < 1e-12) {
      return source;
    }
    return this.callDelegated(name, [source, target]);
  }

  callDelegated(builtinName: string, args: number[], predPtr?: number): number {
    const spec = ABI.builtins[builtinName];
    if (!spec?.supported) return NaN;
    const backend = this.delegateCtx.backend;
    const argc = args.length;
    // bun:ffi rejects empty ArrayBufferViews — keep a 1-slot dummy when argc=0
    // (random/now) or when kinds would otherwise be zero-length.
    const argsBuf = new Float64Array(Math.max(argc, 1));
    const kindsBuf = new Uint8Array(Math.max(argc, 1));
    args.forEach((wire, i) => {
      const kind = spec.args[Math.min(i, spec.args.length - 1)] ?? "number";
      const [value, kindByte] = this.resolveWireArg(kind, wire);
      argsBuf[i] = value;
      kindsBuf[i] = kindByte;
    });
    const argsPtr = backend.ptr(argsBuf);
    const kindsPtr = backend.ptr(kindsBuf);
    const hostPred =
      predPtr !== undefined && Number.isFinite(predPtr) ? this.copyPredicateTree(predPtr) : 0;
    // Null predicate must be a true null pointer (0), not a dummy buffer —
    // otherwise the engine treats random bytes as a Predicate tree.
    // bun:ffi accepts numeric 0 as a null pointer without needing an empty view.
    const predArg = hostPred > 0 ? backend.ptr(hostPred) : 0;
    const result = Number(
      backend.call(
        "mathzig_call_builtin",
        this.delegateCtx.handle,
        spec.id,
        argc,
        argsPtr,
        kindsPtr,
        predArg,
      ),
    );
    // kind 255 = the engine call errored (no result was stashed). Propagate
    // as a throw so error cases stay in parity with the reference engine —
    // a silent NaN would turn "both error" agreement into a mismatch.
    // kind 6 = a legitimate undefined/null result: NaN on the wire, no throw.
    const resultKind = Number(backend.call("mathzig_last_wire_kind"));
    if (resultKind === 255) {
      throw new Error(`MathZig delegated builtin '${builtinName}' failed`);
    }
    if (resultKind === 6) return NaN;
    return this.encodeWireResult(spec, result);
  }

  /** Module exports, for calling user functions (ODE derivatives) by name. */
  private instanceExports: Record<string, unknown> | null = null;

  /**
   * Bind this host to a live instance: capture exports for ODE derivative
   * calls, the module's `alloc` so every host linear-memory write shares
   * the same bump heap as in-module allocations, and `result_kind` for
   * empty-result decode. Pass null to clear (multi-node GraphRunner
   * re-attaches per active node).
   */
  attachInstance(exports: Record<string, unknown> | null): void {
    this.instanceExports = exports;
    // Capture raw module alloc only — inject / high-water live in hostAlloc so
    // call sites that go through hostAlloc are not double-counted.
    const fn = exports?.alloc;
    this.moduleAllocFn = typeof fn === "function" ? (fn as (n: number) => number) : null;
    const rk = exports?.result_kind;
    this.resultKindGlobal =
      rk !== null &&
      rk !== undefined &&
      typeof rk === "object" &&
      "value" in (rk as object)
        ? (rk as WebAssembly.Global)
        : null;
  }

  /**
   * ValueTag discriminant of the last eval result (0 = number). Set by the
   * AOT module on miss/null paths; host uses this when the f64 wire is NaN.
   */
  getLastResultKind(): number {
    if (!this.resultKindGlobal) return 0;
    return Number(this.resultKindGlobal.value);
  }

  /**
   * Env-side ODE driver. Delegation cannot solve ODEs — the derivative is a
   * user function that exists only as a wasm export of this module — so the
   * stepping loop runs host-side, op-for-op like src/functions/ode.zig:
   * result matrix is steps x (1 + dim) with the time column first; the row is
   * written before stepping and the final row gets no step after it.
   */
  private runOdeSolve(
    funcPtr: number,
    y0Ptr: number,
    tSpanPtr: number,
    dt: number,
    method: "euler" | "rk4",
  ): number {
    const mem = this.memory;
    const exports = this.instanceExports;
    if (!mem || !exports || !(dt > 0)) return NaN;
    const funcName = this.readCString(funcPtr);
    if (!funcName) return NaN;
    const deriv = exports[funcName];
    if (typeof deriv !== "function") return NaN;
    const y0Mat = this.readMatrix(y0Ptr);
    const tSpanMat = this.readMatrix(tSpanPtr);
    if (!y0Mat || !tSpanMat) return NaN;
    const y0 = Array.from(y0Mat.data);
    const tSpan = Array.from(tSpanMat.data);
    if (tSpan.length < 2) return NaN;
    const tStart = tSpan[0]!;
    const tEnd = tSpan[tSpan.length - 1]!;
    const dim = y0.length;
    // AOT user-fn params are f64. For dim==1 the compiled deriv body usually
    // treats y as a scalar number (e.g. `-0.5 * y`); for dim>1 it is a matrix
    // pointer (indexed as y[i]). Match that convention when calling exports.
    const scalar = dim === 1;
    const steps = Math.ceil((tEnd - tStart) / dt) + 1;
    if (!Number.isFinite(steps) || steps <= 0 || steps > 10_000_000) return NaN;

    const cols = 1 + dim;
    const resultPtr = this.hostAlloc(8 + steps * cols * 8, 8);
    const yBufPtr = scalar ? 0 : this.hostAlloc(8 + dim * 8, 8);
    if (!resultPtr || (!scalar && !yBufPtr)) return NaN;
    // The deriv call runs module code that may grow memory (heap allocs for
    // returned vectors), detaching any existing view — take fresh DataViews
    // at every write point instead of caching one.
    {
      const dv = new DataView(mem.buffer);
      dv.setInt32(resultPtr, steps, true);
      dv.setInt32(resultPtr + 4, cols, true);
    }

    const callDeriv = (t: number, y: number[]): number[] | null => {
      if (scalar) {
        const r = (deriv as (t: number, y: number) => number)(t, y[0]!);
        return Number.isFinite(r) ? [r] : null;
      }
      const dv = new DataView(mem.buffer);
      dv.setInt32(yBufPtr, dim, true);
      dv.setInt32(yBufPtr + 4, 1, true);
      for (let i = 0; i < dim; i++) dv.setFloat64(yBufPtr + 8 + i * 8, y[i]!, true);
      const rPtr = (deriv as (t: number, yPtr: number) => number)(t, yBufPtr);
      const rMat = this.readMatrix(rPtr);
      if (!rMat || rMat.data.length !== dim) return null;
      return Array.from(rMat.data);
    };

    let t = tStart;
    const y = y0.slice();
    for (let stepIdx = 0; stepIdx < steps; stepIdx++) {
      const dv = new DataView(mem.buffer);
      const base = resultPtr + 8 + stepIdx * cols * 8;
      dv.setFloat64(base, t, true);
      for (let i = 0; i < dim; i++) dv.setFloat64(base + 8 + i * 8, y[i]!, true);
      if (stepIdx === steps - 1) break;

      if (method === "euler") {
        const dy = callDeriv(t, y);
        if (!dy) return NaN;
        for (let i = 0; i < dim; i++) y[i]! += dy[i]! * dt;
      } else {
        const k1 = callDeriv(t, y);
        if (!k1) return NaN;
        const y2 = y.map((v, i) => v + 0.5 * dt * k1[i]!);
        const k2 = callDeriv(t + 0.5 * dt, y2);
        if (!k2) return NaN;
        const y3 = y.map((v, i) => v + 0.5 * dt * k2[i]!);
        const k3 = callDeriv(t + 0.5 * dt, y3);
        if (!k3) return NaN;
        const y4 = y.map((v, i) => v + dt * k3[i]!);
        const k4 = callDeriv(t + dt, y4);
        if (!k4) return NaN;
        for (let i = 0; i < dim; i++) {
          y[i]! += (dt / 6) * (k1[i]! + 2 * k2[i]! + 2 * k3[i]! + k4[i]!);
        }
      }
      t += dt;
    }
    return resultPtr;
  }

  buildEnvForManifest(manifest: AotAbiManifest | null): WasmEnvImports {
    this.stringTable = manifest?.strings ?? {};
    this.stringOffsets = new Set(Object.values(this.stringTable));
    const stubs = buildGeneratedAotStubs(this);
    const env: WasmEnvImports = { ...stubs };
    // Math.sign(NaN) is NaN; Zig `@sign` / VM uses (x>0)-(x<0) so sign(NaN)=0.
    env.sign = (x: number) => (x > 0 ? 1 : x < 0 ? -1 : 0);
    env.ode_solve = (funcPtr, y0Ptr, tSpanPtr, dt) =>
      this.runOdeSolve(funcPtr, y0Ptr, tSpanPtr, dt, "rk4");
    env.ode_solve_euler = (funcPtr, y0Ptr, tSpanPtr, dt) =>
      this.runOdeSolve(funcPtr, y0Ptr, tSpanPtr, dt, "euler");
    // AOT strips unit tags to SI numbers / matrices of SI magnitudes.
    // - Scalar: static fold at compile time, or number+number at runtime.
    // - Matrix: compiler may still import env.conv with (matrix_ptr, unit_scale)
    //   when UnitMeta was lost on the target (load_var of bare unit names).
    //   Elementwise SI → named unit is (x - offset) / scale; linear units use offset=0.
    env.conv = (source: number, target: number) =>
      this.convOrNumberWire(source, target, "conv");
    env.number = (source: number, target?: number) => {
      if (target === undefined || !Number.isFinite(target)) {
        return this.callDelegated("number", target === undefined ? [source] : [source, target]);
      }
      return this.convOrNumberWire(source, target, "number");
    };
    // Compiler-emitted heap intrinsic (not an ABI builtin): dense matmul over
    // raw row-major buffers in wasm memory.
    env.mathzig_gemm = (
      rowsA: number, colsA: number, colsB: number,
      aPtr: number, strideA: number,
      bPtr: number, strideB: number,
      cPtr: number, strideC: number,
    ): number => {
      const mem = this.memory;
      if (!mem) return 0;
      const f64 = new Float64Array(mem.buffer);
      const a = aPtr / 8, b = bPtr / 8, c = cPtr / 8;
      for (let i = 0; i < rowsA; i++) {
        for (let j = 0; j < colsB; j++) {
          let sum = 0;
          for (let k = 0; k < colsA; k++) {
            sum += f64[a + i * strideA + k]! * f64[b + k * strideB + j]!;
          }
          f64[c + i * strideC + j] = sum;
        }
      }
      return 0;
    };
    if (manifest?.imports) {
      for (const imp of manifest.imports) {
        if (!(imp.name in env) && stubs[imp.name]) env[imp.name] = stubs[imp.name];
      }
    }
    return env;
  }

  decodeResult(raw: number, manifest: AotAbiManifest | null): unknown {
    // D3: quiet NaN is transport for empty values; kind side-channel decides
    // undefined vs null vs genuine math NaN. Only consult kind when raw is NaN
    // so leftover intermediate null (slice defaults) cannot relabel matrices.
    if (Number.isNaN(raw)) {
      const kind = this.getLastResultKind();
      // ValueTag.undefined = 12, null_val = 13; wire kind 6 = merged empty.
      if (kind === 12 || kind === 6) return undefined;
      if (kind === 13) return null;
      // kind 0 (number) → fall through as math NaN
    }
    const tag = manifest?.result_tag ?? "number";
    if (tag === "null" || tag === "null_val") {
      return null;
    }
    if (tag === "undefined") {
      return undefined;
    }
    if (tag === "string") {
      const text = this.readLengthPrefixedString(raw);
      if (text !== null) return text;
    }
    if (tag === "matrix") {
      const m = this.readMatrix(raw);
      if (m) return m;
    }
    // AOT may label matrix×unit results as result_tag=number while still
    // returning a matrix pointer (heap or host handle). Prefer matrix when
    // the wire clearly addresses one we know about.
    if (tag === "number" || tag === "unit") {
      const m = this.readMatrix(raw);
      // Only promote heap matrices / host handles (ptr ≥ 1024), never pure small scalars.
      if (m && Math.trunc(raw) >= 1024) return m;
    }
    if (tag === "complex") {
      const c = this.readComplex(raw);
      if (c) return { tag: 1, re: c.re, im: c.im };
    }
    if (tag === "series") {
      // series_repr from custom section: host_handle (default) or linear_memory.
      const repr = (manifest as { series_repr?: string } | null)?.series_repr ?? "host_handle";
      if (repr === "linear_memory") {
        const s = this.readLinearSeries(raw);
        if (s) return { id: Math.trunc(raw), len: () => s.values.length, ...s };
      }
      if (this.seriesStore.has(Math.trunc(raw))) {
        const id = Math.trunc(raw);
        return { id, len: () => this.seriesStore.get(id)!.values.length };
      }
    }
    if (tag === "record") {
      const rec = this.recordStore.get(Math.trunc(raw));
      if (rec) return rec;
      const entries = this.readWasmRecord(raw);
      if (entries) return new Map(entries.map((e) => [e.key, e.wire]));
    }
    // Unit results are SI magnitudes on the wire; result_unit annotation lets
    // hosts re-attach dimensions. Parity compares accept number vs unit tag.
    if (tag === "unit") {
      // ValueTag.unit == 2 in the engine ABI; SI magnitude in `value`.
      const ann = (manifest as { result_unit?: ResultUnitAnnotation } | null)?.result_unit;
      if (Number.isFinite(raw)) {
        return { tag: 2, value: raw, unit: ann ?? null };
      }
      return raw;
    }
    return raw;
  }

  /**
   * Decode a series from linear memory using the single SeriesLayout from
   * abi.zig: [u32 len][u32 pad][f64 ts × len][f64 vals × len].
   */
  readLinearSeries(ptrF64: number): SeriesData | null {
    const mem = this.memory;
    if (!mem || !Number.isFinite(ptrF64)) return null;
    const p = Math.trunc(ptrF64);
    if (p < 0 || p + 8 > mem.buffer.byteLength) return null;
    const dv = new DataView(mem.buffer);
    const len = dv.getUint32(p, true);
    if (len > 1_000_000) return null;
    const total = 8 + len * 16;
    if (p + total > mem.buffer.byteLength) return null;
    const timestamps: number[] = [];
    const values: number[] = [];
    let minTs = Infinity;
    let maxTs = -Infinity;
    for (let i = 0; i < len; i++) {
      const t = dv.getFloat64(p + 8 + i * 8, true);
      const v = dv.getFloat64(p + 8 + len * 8 + i * 8, true);
      timestamps.push(t);
      values.push(v);
      if (t < minTs) minTs = t;
      if (t > maxTs) maxTs = t;
    }
    return { timestamps, values, minTs, maxTs };
  }

  /** Write a series in the abi.zig SeriesLayout into module linear memory. */
  writeLinearSeries(timestamps: number[], values: number[]): number {
    const len = Math.min(timestamps.length, values.length);
    const total = 8 + len * 16;
    const ptr = this.hostAlloc(total, 8);
    if (!ptr) return NaN;
    const mem = this.memory!;
    const dv = new DataView(mem.buffer);
    dv.setUint32(ptr, len, true);
    dv.setUint32(ptr + 4, 0, true);
    for (let i = 0; i < len; i++) {
      dv.setFloat64(ptr + 8 + i * 8, timestamps[i] ?? 0, true);
      dv.setFloat64(ptr + 8 + len * 8 + i * 8, values[i] ?? NaN, true);
    }
    return ptr;
  }
}

/** Unit annotation from the mathzig.abi custom section (task-07). */
export type ResultUnitAnnotation = {
  dims: { m: number; l: number; t: number; i: number; k: number; n: number; j: number };
  scale: number;
  offset: number;
  name?: string;
};

export function createAotHostEnv(delegateCtx?: MathZig): AotHostEnv {
  return new AotHostEnv(delegateCtx);
}

export function createDefaultWasmEnv(overrides: Partial<WasmEnvImports> = {}): WasmEnvImports {
  const host = createAotHostEnv();
  return { ...host.buildEnvForManifest(null), ...overrides };
}

const CUSTOM_SECTION = (aotAbi as { custom_section?: string }).custom_section ?? "mathzig.abi";

export function readAbiManifest(module: WebAssembly.Module): AotAbiManifest | null {
  const sections = WebAssembly.Module.customSections(module, CUSTOM_SECTION);
  if (sections.length === 0) return null;
  return JSON.parse(new TextDecoder().decode(sections[0])) as AotAbiManifest;
}