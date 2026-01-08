import * as fs from "node:fs";
import * as path from "node:path";
import { createHash } from "node:crypto";
import { createDefaultWasmEnv as createAotWasmEnv, type WasmEnvImports } from "../../src/ts/aot_env";

export { createAotWasmEnv as createDefaultWasmEnv, type WasmEnvImports };

const BIN_PATH = process.env.MATHZIG_BIN
  ? path.resolve(process.env.MATHZIG_BIN)
  : path.resolve("zig-out/bin/mathzig");
const DEFAULT_AOT_DIR = path.resolve("tests/artifacts/wasm_aot");

if (!fs.existsSync(DEFAULT_AOT_DIR)) fs.mkdirSync(DEFAULT_AOT_DIR, { recursive: true });

type CompileOptions = {
  id?: string;
  outDir?: string;
  keepArtifacts?: boolean;
  quiet?: boolean;
  deterministic?: boolean;
  verbose?: boolean;
  /** Pass `-s/--standalone` so the module has no env imports. */
  standalone?: boolean;
};

function hashExpr(expr: string, numParams: number, standalone = false): string {
  return createHash("sha1").update(`${expr}|${numParams}|s=${standalone ? 1 : 0}`).digest("hex");
}

export function createDefaultWasmImports(overrides: Partial<WasmEnvImports> = {}) {
  return { env: createAotWasmEnv(overrides) };
}

export async function runMathZigCompiler(expr: string, numParams: number = 0, opts: CompileOptions = {}): Promise<Buffer> {
  const deterministic = opts.deterministic ?? true;
  const standalone = opts.standalone === true;
  const id = opts.id ?? (deterministic ? hashExpr(expr, numParams, standalone) : Math.random().toString(36).substring(7));
  const outDir = opts.outDir ?? DEFAULT_AOT_DIR;
  const keepArtifacts = opts.keepArtifacts ?? true;
  const logCompiler = opts.verbose === true && opts.quiet !== true;
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  const inFile = path.join(outDir, `${id}.mz`);
  const outFile = path.join(outDir, `${id}.wasm`);

  await Bun.write(inFile, expr);

  try {
    const compileArgs = [BIN_PATH, "compile", "-i", inFile, "-o", outFile];
    if (numParams > 0) compileArgs.push("-p", numParams.toString());
    if (standalone) compileArgs.push("-s");

    const proc = Bun.spawn(compileArgs, { stderr: "pipe", stdout: "pipe" });
    const timeout = new Promise<number>((_, reject) =>
      setTimeout(() => {
        proc.kill();
        reject(new Error("Compiler timed out after 3000ms"));
      }, 3000),
    );

    const exitCode = await Promise.race([proc.exited, timeout]);
    const out = await new Response(proc.stdout).text();
    const err = await new Response(proc.stderr).text();

    if (logCompiler) {
      console.log(`Compiler STDOUT: ${out}`);
      console.log(`Compiler STDERR: ${err}`);
    }

    if (exitCode !== 0) {
      throw new Error(`Compiler failed:\nSTDOUT: ${out}\nSTDERR: ${err}`);
    }

    return fs.readFileSync(outFile);
  } finally {
    if (!keepArtifacts) {
      if (fs.existsSync(inFile)) fs.unlinkSync(inFile);
      if (fs.existsSync(outFile)) fs.unlinkSync(outFile);
    }
  }
}