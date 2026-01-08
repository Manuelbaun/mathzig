#!/usr/bin/env bun
import * as fs from "node:fs";
import * as path from "node:path";

type Metrics = {
  size_bytes: number;
  instr_count: number | null;
  op_hist: Record<string, number> | null;
};

type CaseDef = {
  id: string;
  dsl: string;
  params?: string[];
  zig_expr?: string;
  zig_helpers?: string;
  zig_source?: string;
};

type CompareResult = {
  id: string;
  dsl: string;
  params: string[];
  mathzig: Metrics;
  zig: Metrics;
  size_ratio: number | null;
  instr_ratio: number | null;
  op_hist_diff: Record<string, { mathzig: number; zig: number; delta: number; ratio: number | null }> | null;
  ok: boolean;
};

type Args = {
  cases: string;
  outDir: string;
  sizeTol: number;
  instrTol: number;
  jsonOut: string | null;
  topOps: number;
};

const DEFAULT_ARGS: Args = {
  cases: "tools/wasm/wasm_compare/cases.json",
  outDir: "/tmp/wasm_compare",
  sizeTol: 0.10,
  instrTol: 0.10,
  jsonOut: null,
  topOps: 8,
};

function parseArgs(argv: string[]): Args {
  const out: Args = { ...DEFAULT_ARGS };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) throw new Error(`Missing value for ${a}`);
      i += 1;
      return argv[i];
    };
    switch (a) {
      case "--cases":
        out.cases = next();
        break;
      case "--out-dir":
        out.outDir = next();
        break;
      case "--size-tol":
        out.sizeTol = Number(next());
        break;
      case "--instr-tol":
        out.instrTol = Number(next());
        break;
      case "--json":
        out.jsonOut = next();
        break;
      case "--top-ops":
        out.topOps = Number(next());
        break;
      default:
        throw new Error(`Unknown arg: ${a}`);
    }
  }
  if (!Number.isFinite(out.sizeTol) || out.sizeTol < 0) throw new Error("Invalid --size-tol");
  if (!Number.isFinite(out.instrTol) || out.instrTol < 0) throw new Error("Invalid --instr-tol");
  if (!Number.isFinite(out.topOps) || out.topOps < 0) throw new Error("Invalid --top-ops");
  return out;
}

function run(cmd: string[], cwd?: string, env?: NodeJS.ProcessEnv) {
  const res = Bun.spawnSync({
    cmd,
    cwd,
    env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = new TextDecoder().decode(res.stdout ?? new Uint8Array());
  const stderr = new TextDecoder().decode(res.stderr ?? new Uint8Array());
  if (res.exitCode !== 0) {
    throw new Error(
      `${cmd.join(" ")} failed (${res.exitCode})${stderr.trim() ? `\n${stderr.trim()}` : stdout.trim() ? `\n${stdout.trim()}` : ""}`
    );
  }
  return stdout;
}

function existsOnPath(bin: string): boolean {
  return Bun.which(bin) != null;
}

function ensureMathzig(root: string): string {
  const binPath = path.join(root, "zig-out", "bin", "mathzig");
  if (fs.existsSync(binPath)) return binPath;
  run(["zig", "build", "-Doptimize=ReleaseSmall"], root);
  if (!fs.existsSync(binPath)) throw new Error("mathzig binary not found after build");
  return binPath;
}

function compileMathzig(binPath: string, expr: string, params: number, outPath: string) {
  const res = Bun.spawnSync({
    cmd: [binPath, "compile", expr, "-p", String(params), "-o", outPath],
    stdout: "ignore",
    stderr: "pipe",
  });
  if (res.exitCode !== 0) {
    const stderr = new TextDecoder().decode(res.stderr ?? new Uint8Array());
    throw new Error(`mathzig compile failed for expr '${expr}': ${stderr.trim()}`);
  }
}

function buildZigSource(c: CaseDef): string {
  if (c.zig_source && c.zig_source.length > 0) return c.zig_source;
  if (!c.zig_expr) throw new Error(`Case '${c.id}' missing zig_expr or zig_source`);
  const params = c.params ?? [];
  const zigParams = params.map((p) => `${p}: f64`).join(", ");
  const zigHelpers = (c.zig_helpers ?? "").replaceAll("\\n", "\n");
  const helperBlock = zigHelpers ? `\n${zigHelpers}\n` : "\n";
  return (
    "// Auto-generated Zig baseline for WASM comparison\n" +
    helperBlock +
    `export fn eval(${zigParams}) f64 {\n` +
    `    return ${c.zig_expr};\n` +
    "}\n"
  );
}

function compileZig(root: string, zigSrc: string, outPath: string, cacheDir: string, globalCache: string) {
  const tmpPath = `${outPath}.zig`;
  fs.writeFileSync(tmpPath, zigSrc, "utf8");
  const env: NodeJS.ProcessEnv = { ...process.env, ZIG_CACHE_DIR: cacheDir, ZIG_GLOBAL_CACHE_DIR: globalCache };
  run(
    [
      "zig",
      "build-exe",
      tmpPath,
      "-target",
      "wasm32-freestanding",
      "-fno-entry",
      "-O",
      "ReleaseSmall",
      "-rdynamic",
      `-femit-bin=${outPath}`,
    ],
    root,
    env
  );
}

function parseEvalInstructions(wasmPath: string): { instrCount: number | null; opHist: Record<string, number> | null } {
  if (!existsOnPath("wasm-objdump")) return { instrCount: null, opHist: null };
  const text = run(["wasm-objdump", "-d", wasmPath]);
  const lines = text.split(/\r?\n/);
  let inEval = false;
  let instrCount = 0;
  const opHist: Record<string, number> = {};
  for (const line of lines) {
    const l = line.trimEnd();
    if (l.startsWith("000") && l.includes("func[") && l.includes("<") && l.includes(">:")) {
      const name = l.split("<", 2)[1]?.split(">", 1)[0] ?? "";
      inEval = name === "eval";
      continue;
    }
    if (!inEval) continue;
    if (!l.includes("|")) continue;
    const rhs = l.split("|", 2)[1]?.trim() ?? "";
    const op = rhs.split(" ", 1)[0];
    if (!op || op.startsWith("local[") || op === "end") continue;
    instrCount += 1;
    opHist[op] = (opHist[op] ?? 0) + 1;
  }
  return { instrCount, opHist };
}

function metricsFor(wasmPath: string): Metrics {
  const size = fs.statSync(wasmPath).size;
  const { instrCount, opHist } = parseEvalInstructions(wasmPath);
  return { size_bytes: size, instr_count: instrCount, op_hist: opHist };
}

function ratio(a: number | null, b: number | null): number | null {
  if (a == null || b == null || b === 0) return null;
  return a / b;
}

function fmtRatio(r: number | null): string {
  return r == null ? "n/a" : `${r.toFixed(2)}x`;
}

function diffHist(
  mz: Record<string, number> | null,
  zz: Record<string, number> | null
): Record<string, { mathzig: number; zig: number; delta: number; ratio: number | null }> | null {
  if (!mz || !zz) return null;
  const keys = new Set([...Object.keys(mz), ...Object.keys(zz)]);
  const out: Record<string, { mathzig: number; zig: number; delta: number; ratio: number | null }> = {};
  for (const k of keys) {
    const m = mz[k] ?? 0;
    const z = zz[k] ?? 0;
    out[k] = { mathzig: m, zig: z, delta: m - z, ratio: z === 0 ? null : m / z };
  }
  return out;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(import.meta.dir, "../../..");
  fs.mkdirSync(args.outDir, { recursive: true });
  fs.mkdirSync("/tmp/zig-cache", { recursive: true });
  fs.mkdirSync("/tmp/zig-global-cache", { recursive: true });

  const casesPath = path.isAbsolute(args.cases) ? args.cases : path.join(root, args.cases);
  const cases = JSON.parse(fs.readFileSync(casesPath, "utf8")) as CaseDef[];

  const mathzigBin = ensureMathzig(root);
  const results: CompareResult[] = [];
  let anyFail = false;

  for (const c of cases) {
    const params = c.params ?? [];
    const mathzigWasm = path.join(args.outDir, `mathzig_${c.id}.wasm`);
    const zigWasm = path.join(args.outDir, `zig_${c.id}.wasm`);

    compileMathzig(mathzigBin, c.dsl, params.length, mathzigWasm);
    const zigSrc = buildZigSource(c);
    compileZig(root, zigSrc, zigWasm, "/tmp/zig-cache", "/tmp/zig-global-cache");

    const mz = metricsFor(mathzigWasm);
    const zz = metricsFor(zigWasm);
    const sizeRatio = ratio(mz.size_bytes, zz.size_bytes);
    const instrRatio = ratio(mz.instr_count, zz.instr_count);
    const histDiff = diffHist(mz.op_hist, zz.op_hist);

    const sizeOk = sizeRatio != null && sizeRatio <= 1.0 + args.sizeTol;
    const instrOk = instrRatio == null || instrRatio <= 1.0 + args.instrTol;
    const ok = sizeOk && instrOk;
    if (!ok) anyFail = true;

    results.push({
      id: c.id,
      dsl: c.dsl,
      params,
      mathzig: mz,
      zig: zz,
      size_ratio: sizeRatio,
      instr_ratio: instrRatio,
      op_hist_diff: histDiff,
      ok,
    });
  }

  const header = `${"case".padEnd(20)}  ${"size".padStart(10)}  ${"instr".padStart(10)}  ${"status".padStart(6)}`;
  console.log(header);
  console.log("-".repeat(header.length));
  for (const r of results) {
    const status = r.ok ? "OK" : "FAIL";
    console.log(`${r.id.padEnd(20)}  ${fmtRatio(r.size_ratio).padStart(10)}  ${fmtRatio(r.instr_ratio).padStart(10)}  ${status.padStart(6)}`);
  }

  if (args.topOps > 0) {
    for (const r of results) {
      const diff = r.op_hist_diff;
      if (!diff) continue;
      const deltas: Array<[number, string, number]> = [];
      for (const [op, stats] of Object.entries(diff)) {
        if (stats.delta !== 0) deltas.push([Math.abs(stats.delta), op, stats.delta]);
      }
      if (deltas.length === 0) continue;
      deltas.sort((a, b) => b[0] - a[0]);
      const top = deltas.slice(0, args.topOps).map(([, op, delta]) => `${op}:${delta > 0 ? "+" : ""}${Math.trunc(delta)}`);
      console.log(`Top opcode deltas (${r.id}): ${top.join(", ")}`);
    }
  }

  const payload = JSON.stringify({ results }, null, 2);
  if (args.jsonOut) {
    fs.writeFileSync(args.jsonOut, `${payload}\n`, "utf8");
  } else {
    const reportPath = path.join(args.outDir, "report.json");
    fs.writeFileSync(reportPath, `${payload}\n`, "utf8");
    console.log(`Report: ${reportPath}`);
  }

  process.exit(anyFail ? 1 : 0);
}

main();
