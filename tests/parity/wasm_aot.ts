import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { createHash } from "node:crypto";
import { runMathZigCompiler } from "../ts/wasm_utils";

export interface WasmAotCompileResult {
  wasmBytes: Uint8Array;
}

export type CompileAotOptions = {
  standalone?: boolean;
};

function hashKey(expr: string, numParams: number, standalone = false): string {
  return createHash("sha1").update(`${expr}|${numParams}|s=${standalone ? 1 : 0}`).digest("hex");
}

export async function compileAot(
  expr: string,
  numParams: number = 0,
  opts: CompileAotOptions = {},
): Promise<WasmAotCompileResult> {
  const cacheDir = resolve("tests/artifacts/wasm_aot");
  mkdirSync(cacheDir, { recursive: true });
  const standalone = opts.standalone === true;

  const key = hashKey(expr, numParams, standalone);
  const cachePath = resolve(cacheDir, `${key}.wasm`);

  if (existsSync(cachePath)) {
    const bytes = readFileSync(cachePath);
    return { wasmBytes: new Uint8Array(bytes) };
  }

  const buffer = await runMathZigCompiler(expr, numParams, { standalone });
  writeFileSync(cachePath, buffer);
  return { wasmBytes: new Uint8Array(buffer) };
}
