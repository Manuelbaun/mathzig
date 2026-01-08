const root = process.cwd();

function runZig(step: string, args: string[]) {
  console.log(`\n=== ${step} ===`);
  const res = Bun.spawnSync({
    cmd: ["zig", "build", ...args],
    cwd: root,
    env: process.env,
    stdout: "inherit",
    stderr: "inherit",
  });
  if (res.exitCode !== 0) {
    process.exit(res.exitCode ?? 1);
  }
}

console.log("=== MathZig Build ===");

runZig("Native (FFI + CLI)", ["-Doptimize=ReleaseFast"]);
runZig("WebAssembly (web/mathzig_wasm.wasm)", ["wasm"]);

console.log("\nBuild complete.");
console.log("  Native: zig-out/bin/");
console.log("  Web:    web/mathzig_wasm.wasm");