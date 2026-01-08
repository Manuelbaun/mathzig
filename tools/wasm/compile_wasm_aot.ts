#!/usr/bin/env bun
import * as fs from "node:fs";
import * as path from "node:path";
import { createHash } from "node:crypto";
import { runMathZigCompiler } from "../../tests/ts/wasm_utils";

function usage(): never {
  console.error("Usage: bun tools/wasm/compile_wasm_aot.ts (--expr '<expr>' | --input <file>) [--out <file.wasm>] [--params <n>]");
  process.exit(1);
}

function readArg(args: string[], key: string): string | undefined {
  const idx = args.indexOf(key);
  if (idx < 0 || idx + 1 >= args.length) return undefined;
  return args[idx + 1];
}

function hashExpr(expr: string, numParams: number): string {
  return createHash("sha1").update(`${expr}|${numParams}`).digest("hex");
}

async function main() {
  const args = process.argv.slice(2);
  const exprArg = readArg(args, "--expr");
  const inputArg = readArg(args, "--input");
  const outArg = readArg(args, "--out");
  const paramsArg = readArg(args, "--params");

  if ((exprArg ? 1 : 0) + (inputArg ? 1 : 0) !== 1) usage();

  const expr = exprArg ?? fs.readFileSync(path.resolve(inputArg!), "utf8");
  const params = paramsArg ? Number.parseInt(paramsArg, 10) : 0;
  if (!Number.isFinite(params) || params < 0) usage();

  const outPath = outArg ? path.resolve(outArg) : undefined;
  const outDir = outPath ? path.dirname(outPath) : undefined;
  const outId = outPath ? path.basename(outPath, ".wasm") : hashExpr(expr, params);

  const bytes = await runMathZigCompiler(expr, params, {
    outDir,
    id: outId,
    deterministic: true,
    keepArtifacts: true,
    quiet: true,
  });

  if (outPath) {
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, bytes);
    console.log(outPath);
    return;
  }

  const defaultPath = path.resolve("tests/artifacts/wasm_aot", `${outId}.wasm`);
  console.log(defaultPath);
}

main().catch((err) => {
  console.error(String(err?.message ?? err));
  process.exit(1);
});
