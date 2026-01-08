import { MathZig } from "../../../src/ts/mathzig";

const ITERATIONS = Number(Bun.env.BENCH_ITERS ?? 20000);
const COUNT = Number(Bun.env.BENCH_COUNT ?? 256);

function bench(name: string, fn: () => void) {
  const t0 = performance.now();
  fn();
  const t1 = performance.now();
  const ms = t1 - t0;
  const ops = (ITERATIONS / (ms / 1000) / 1e6).toFixed(2);
  console.log(`${name.padEnd(38)}: ${ms.toFixed(2)}ms (${ops} M ops/sec)`);
}

const ctx = MathZig.create();
const xIdx = ctx.addVariableIndexed("x", 0);
const expr = ctx.compile("x * 2 + 1");
const inputArray = Array.from({ length: COUNT }, (_, i) => i);
const output = new Float64Array(COUNT);

console.log("TS Wrapper Allocation Benchmark");
console.log("=============================");
console.log(`iterations=${ITERATIONS}, batch_count=${COUNT}\n`);

bench("evaluateBatch(array)->new array", () => {
  for (let i = 0; i < ITERATIONS; i++) {
    expr.evaluateBatch(xIdx, inputArray);
  }
});

bench("evaluateBatch(array, out buffer)", () => {
  for (let i = 0; i < ITERATIONS; i++) {
    expr.evaluateBatch(xIdx, inputArray, output, COUNT);
  }
});

expr.free();
ctx.destroy();
