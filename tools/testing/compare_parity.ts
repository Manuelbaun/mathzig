import * as fs from "node:fs";
import * as path from "node:path";

type Backend = "zig_vm" | "ts_ffi" | "ts_wasm_vm" | "wasm_aot";

const baselineId = process.argv[2];
const afterId = process.argv[3];

if (!baselineId || !afterId) {
  console.error("Usage: bun tools/testing/compare_parity.ts <baseline_id> <after_id>");
  process.exit(1);
}

const artDir = path.resolve(process.cwd(), "tests/artifacts/parity");
if (!fs.existsSync(artDir) || !fs.statSync(artDir).isDirectory()) {
  console.error(`Missing ${path.relative(process.cwd(), artDir)}`);
  process.exit(1);
}

const backends: Backend[] = ["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"];

function readFailRows(file: string): string[] {
  return fs
    .readFileSync(file, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.includes(",FAIL,"));
}

for (const backend of backends) {
  const baseFile = path.join(artDir, `${baselineId}_${backend}.csv`);
  const afterFile = path.join(artDir, `${afterId}_${backend}.csv`);

  if (!fs.existsSync(baseFile) || !fs.existsSync(afterFile)) {
    console.log(`${backend}: missing baseline or after file`);
    console.log("");
    continue;
  }

  const baseFails = readFailRows(baseFile);
  const afterFails = readFailRows(afterFile);
  console.log(`${backend}: FAIL ${baseFails.length} -> ${afterFails.length}`);

  if (baseFails.length !== afterFails.length) {
    console.log(`${backend}: diff (FAIL rows)`);
    const onlyBaseline = baseFails.filter((line) => !afterFails.includes(line));
    const onlyAfter = afterFails.filter((line) => !baseFails.includes(line));
    for (const line of onlyBaseline) console.log(`- baseline only: ${line}`);
    for (const line of onlyAfter) console.log(`+ after only: ${line}`);
  }

  console.log("");
}
