
import { dlopen, ptr, toArrayBuffer } from "bun:ffi";

const libPath = "zig-out/lib/libmathzig.dylib";
const lib = dlopen(libPath, {
  mathzig_create: { args: [], returns: "ptr" },
  mathzig_destroy: { args: ["ptr"], returns: "void" },
  mathzig_compile: { args: ["ptr", "ptr"], returns: "ptr" }, // expr string
  mathzig_alloc_aligned: { args: ["u64", "u64"], returns: "ptr" },
  mathzig_free: { args: ["ptr"], returns: "void" },
  mathzig_batch_eval_simd: { args: ["ptr", "ptr", "u8", "ptr", "ptr", "u32"], returns: "void" },
  mathzig_add_variable_indexed: { args: ["ptr", "ptr", "f64"], returns: "ptr" }, // returns index (ptr/number)
});

const ctx = lib.symbols.mathzig_create();
if (!ctx) { console.error("Ctx null"); process.exit(1); }

console.log("Context created:", ctx);

// Add variable x
const xName = Buffer.from("x\0");
const xIdx = Number(lib.symbols.mathzig_add_variable_indexed(ctx, ptr(xName), 0));
console.log("xIdx:", xIdx);

// Compile 'x * 2'
const exprStr = Buffer.from("x * 2\0");
const expr = lib.symbols.mathzig_compile(ctx, ptr(exprStr));
if (!expr) { console.error("Expr null"); process.exit(1); }
console.log("Expr compiled:", expr);

// Alloc buffers
const count = 4;
const inPtr = lib.symbols.mathzig_alloc_aligned(64n, BigInt(count * 8));
const outPtr = lib.symbols.mathzig_alloc_aligned(64n, BigInt(count * 8));

console.log("inPtr:", inPtr);
console.log("outPtr:", outPtr);

// Fill input
const inBuf = toArrayBuffer(inPtr, 0, count * 8);
const inArr = new Float64Array(inBuf, 0, count);
inArr.set([1, 2, 3, 4]);

// Eval
console.log("Calling evaluateBatchSIMD...");
try {
  lib.symbols.mathzig_batch_eval_simd(ctx, expr, xIdx, inPtr, outPtr, count);
  console.log("Success!");
  
  const outBuf = toArrayBuffer(outPtr, 0, count * 8);
  const outArr = new Float64Array(outBuf, 0, count);
  console.log("Output:", Array.from(outArr));

} catch (e) {
  console.error("Crash or error:", e);
}

// Cleanup... skipped for brevity
