import * as fs from "node:fs";
import * as path from "node:path";

const inputFile = path.resolve(process.cwd(), "zig-out/bin/mathzig_wasm.wasm");
const outputFile = path.resolve(process.cwd(), "web/mathzig_wasm.wasm");

function humanBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  const units = ["KiB", "MiB", "GiB"];
  let value = bytes;
  let index = -1;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(2)}${units[index]}`;
}

function hasTool(name: string): boolean {
  return Bun.which(name) != null;
}

function runOrThrow(cmd: string[], label: string) {
  const res = Bun.spawnSync({ cmd, stdout: "pipe", stderr: "pipe" });
  if (res.exitCode !== 0) {
    const stdout = new TextDecoder().decode(res.stdout ?? new Uint8Array());
    const stderr = new TextDecoder().decode(res.stderr ?? new Uint8Array());
    const msg = `${label} failed\n${stderr || stdout}`;
    throw new Error(msg.trim());
  }
}

if (!fs.existsSync(inputFile)) {
  console.error(`Error: Input file '${path.relative(process.cwd(), inputFile)}' not found.`);
  console.error("Please run 'zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall' first.");
  process.exit(1);
}

console.log("=== MathZig WASM Optimizer ===");
console.log(`Input:  ${path.relative(process.cwd(), inputFile)}`);
console.log(`Output: ${path.relative(process.cwd(), outputFile)}`);

const originalSize = fs.statSync(inputFile).size;
console.log(`Original size: ${humanBytes(originalSize)}`);

fs.mkdirSync(path.dirname(outputFile), { recursive: true });
fs.copyFileSync(inputFile, outputFile);

let missingTools = false;

if (hasTool("wasm-strip")) {
  console.log("Found wasm-strip (WABT)");
  runOrThrow(["wasm-strip", outputFile], "wasm-strip");
  console.log("  Stripped debug symbols.");
} else {
  console.log("wasm-strip not found (skipping)");
  missingTools = true;
}

if (hasTool("wasm-opt")) {
  console.log("Found wasm-opt (Binaryen)");
  runOrThrow(["wasm-opt", "-Oz", outputFile, "-o", outputFile], "wasm-opt");
  console.log("  Optimized for size (-Oz).");
} else {
  console.log("wasm-opt not found (skipping)");
  missingTools = true;
}

const finalSize = fs.statSync(outputFile).size;
const diff = originalSize - finalSize;
const percent = originalSize === 0 ? 0 : (diff * 100) / originalSize;

console.log("=== Optimization Results ===");
console.log(`Final size:    ${humanBytes(finalSize)}`);
console.log(`Reduction:     ${humanBytes(diff)} (-${percent.toFixed(2)}%)`);

if (missingTools) {
  console.log("Install missing tools for better compression:");
  console.log("  macOS: brew install binaryen wabt");
  console.log("  Linux: apt install binaryen wabt");
}
