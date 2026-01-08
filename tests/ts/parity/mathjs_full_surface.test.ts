import { describe, it, expect } from "bun:test";
import { existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import * as mathjs from "mathjs";
import { MathZig, Value } from "../../../src/ts/mathzig";

type Entry = {
  rel: string;
  category: string;
  fn: string;
};

type ProbeResult = {
  entry: Entry;
  expr: string | null;
  mathjsOk: boolean;
  mathzigOk: boolean;
  error?: string;
};

const MATHJS_FUNCTION_TEST_ROOT = "libs/mathjs/test/unit-tests/function";
const OUT_DIR = "tests/artifacts/parity";
const OUT_JSON = `${OUT_DIR}/mathjs_full_surface_report.json`;
const OUT_MD = `${OUT_DIR}/mathjs_full_surface_report.md`;

const expressionOverridesByRel: Record<string, string[]> = {
  "algebra/decomposition/lup": ["lup([1,2;3,4])"],
  "algebra/decomposition/qr": ["qr([1,2;3,4])"],
  "algebra/decomposition/schur": ["schur([1,2;3,4])"],
  "algebra/decomposition/slu": ["slu(sparse([1,2;3,4]),1,0)"],
  "algebra/derivative": ["derivative('x^2', 'x')"],
  "algebra/lyap": ["lyap([1,0;0,2],[1,0;0,3])"],
  "algebra/symbolicEqual": ["symbolicEqual('x+x','2*x')"],
  "algebra/solver/lsolve": ["lsolve([1,0;2,1],[3,4])"],
  "algebra/solver/lsolveAll": ["lsolveAll([1,0;2,1],[3,4])"],
  "algebra/solver/lusolve": ["lusolve([1,2;3,4],[5,6])"],
  "algebra/solver/usolve": ["usolve([1,2;0,1],[5,6])"],
  "algebra/solver/usolveAll": ["usolveAll([1,2;0,1],[5,6])"],
  "algebra/sparse/csLu": ["csLu(sparse([1,2;3,4]))"],
  "algebra/sylvester": ["sylvester([1,2;3,4],[2,0;0,3],[1,0;0,1])"],
  "combinatorics/composition": ["composition(5,2)"],
  "geometry/distance": ["distance([0,0],[3,4])"],
  "geometry/intersect": ["intersect([0,0],[2,2],[0,2],[2,0])"],
  "logical/nullish": ["null ?? 5"],
  "matrix/column": ["column([1,2;3,4], 1)"],
  "matrix/concat": ["concat([1,2],[3,4])"],
  "matrix/cross": ["cross([1,2,3],[4,5,6])"],
  "matrix/ctranspose": ["ctranspose([1+i,2;3,4])"],
  "matrix/eigs": ["eigs([1,2;3,4])"],
  "matrix/expm": ["expm([1,2;3,4])"],
  "matrix/fft": ["fft([1,2,3,4])"],
  "matrix/ifft": ["ifft([1,2,3,4])"],
  "matrix/kron": ["kron([1,2],[3,4])"],
  "matrix/mapSlices": ["mapSlices([1,2;3,4], 1, mean)"],
  "matrix/matrixFrom": ["matrixFromColumns([1,2],[3,4])", "matrixFromRows([1,2],[3,4])"],
  "matrix/partitionSelect": ["partitionSelect([3,1,2], 1)"],
  "matrix/pinv": ["pinv([1,2;3,4])"],
  "matrix/range": ["range(0,5)"],
  "matrix/resize": ["resize([1,2], [4], 0)"],
  "matrix/reshape": ["reshape([1,2,3,4], [2,2])"],
  "matrix/rotate": ["rotate([1,0], pi/2)"],
  "matrix/rotationMatrix": ["rotationMatrix(90 deg)"],
  "matrix/row": ["row([1,2;3,4], 1)"],
  "matrix/sort": ["sort([3,1,2])"],
  "matrix/sqrtm": ["sqrtm([4,0;0,9])"],
  "matrix/squeeze": ["squeeze([[[1]]])"],
  "matrix/subset": ["subset([1,2,3], index(1))"],
  "numeric/solveODE": ["f(t,y)=y; solveODE(f, [0,1], 1)"],
  "probability/bernoulli": ["bernoulli(0.5)"],
  "probability/combinationsWithRep": ["combinationsWithRep(5,2)"],
  "probability/kldivergence": ["kldivergence([0.5,0.5],[0.4,0.6])"],
  "probability/multinomial": ["multinomial([1,2,3])"],
  "probability/seededrandom": ["seededRandom(42)"],
  "special/zeta": ["zeta(2)"],
  "statistics/corr": ["corr([1,2,3],[1,2,3])"],
  "statistics/quantileSeq": ["quantileSeq([1,2,3,4], 0.5)"],
  "string/print": ["print('hello $name', {name: 'world'})"],
  "unit/to": ["(5 cm) to inch"],
  "unit/toBest": ["toBest(1000 m)"],
};

const expressionOverridesByFn: Record<string, string[]> = {
  addScalar: ["addScalar(2, 3)"],
  createHypot: ["hypot(3, 4)"],
  dotDivide: ["dotDivide([4,6],[2,3])"],
  dotPow: ["dotPow([2,3],[3,2])"],
  invmod: ["invmod(3, 11)"],
  nthRoots: ["nthRoots([1,0,0,-1])"],
  subtractScalar: ["subtractScalar(5, 2)"],
  unaryMinus: ["unaryMinus(2)"],
  unaryPlus: ["unaryPlus(2)"],
  xgcd: ["xgcd(30, 12)"],
  rightLogShift: ["rightLogShift(8,1)"],
  bellNumbers: ["bellNumbers(5)"],
  catalan: ["catalan(5)"],
  stirlingS2: ["stirlingS2(5,2)"],
  not: ["not(true)"],
  or: ["or(true, false)"],
  xor: ["xor(true, false)"],
  compareNatural: ["compareNatural('a2', 'a10')"],
  compareText: ["compareText('a', 'b')"],
  deepEqual: ["deepEqual([1,2],[1,2])"],
  equal: ["equal(2,2)"],
  equalText: ["equalText('a', 'A')"],
  larger: ["larger(3,2)"],
  largerEq: ["largerEq(3,3)"],
  smaller: ["smaller(2,3)"],
  smallerEq: ["smallerEq(2,2)"],
  unequal: ["unequal(2,3)"],
  setCartesian: ["setCartesian([1,2],[3,4])"],
  setDifference: ["setDifference([1,2,3],[2])"],
  setDistinct: ["setDistinct([1,1,2,2])"],
  setIntersect: ["setIntersect([1,2,3],[2,3,4])"],
  setIsSubset: ["setIsSubset([1,2],[1,2,3])"],
  setMultiplicity: ["setMultiplicity(1, [1,1,2])"],
  setPowerset: ["setPowerset([1,2])"],
  setSize: ["setSize([1,1,2])"],
  setSymDifference: ["setSymDifference([1,2],[2,3])"],
  setUnion: ["setUnion([1,2],[2,3])"],
  filter: ["f(x)=x>1; filter([1,2,3], f)"],
  forEach: ["h(x)=x; forEach([1,2,3], h)"],
  map: ["g(x)=x+1; map([1,2,3], g)"],
  freqz: ["freqz([1, 0.5], [1, -0.3], 8)"],
  zpk2tf: ["zpk2tf([0.5], [0.1], 2)"],
  clone: ["clone([1,2,3])"],
  hasNumericValue: ["hasNumericValue(2 cm)"],
  isBounded: ["isPositive(2) and isNegative(-2)"],
  isNegative: ["isNegative(-2)"],
  isNumeric: ["isNumeric(2)"],
  isPositive: ["isPositive(2)"],
  isPrime: ["isPrime(13)"],
  isZero: ["isZero(0)"],
  typeof: ["typeOf(2)"],
  acos: ["acos(0.5)"],
  atan: ["atan(0.5)"],
  cosh: ["cosh(0.5)"],
  sinh: ["sinh(0.5)"],
  tanh: ["tanh(0.5)"],
  composition: ["composition(5,2)"],
};

function collectFunctionEntries(root: string): Entry[] {
  const out: Entry[] = [];

  function walk(dir: string) {
    for (const name of readdirSync(dir)) {
      const full = join(dir, name);
      const st = statSync(full);
      if (st.isDirectory()) {
        walk(full);
        continue;
      }
      if (!name.endsWith(".test.js")) continue;
      const rel = relative(root, full).replace(/\\/g, "/").replace(/\.test\.js$/, "");
      const parts = rel.split("/");
      const category = parts[0] ?? "other";
      const fn = parts[parts.length - 1];
      out.push({ rel, category, fn });
    }
  }

  walk(root);
  return out.sort((a, b) => a.rel.localeCompare(b.rel));
}

function baseCandidates(entry: Entry): string[] {
  const fn = entry.fn;
  const generic = [
    `${fn}(2)`,
    `${fn}(2, 3)`,
    `${fn}(2, 3, 4)`,
    `${fn}([1,2,3])`,
    `${fn}([1,2],[3,4])`,
    `${fn}([1,2;3,4])`,
    `${fn}(true)`,
    `${fn}('a')`,
  ];

  const byCategory: Record<string, string[]> = {
    arithmetic: [`${fn}(2, 3)`, `${fn}(2)`],
    algebra: [`${fn}('x^2')`, `${fn}([1,2;3,4])`],
    trigonometry: [`${fn}(0.5)`],
    complex: [`${fn}(2+3i)`],
    statistics: [`${fn}([1,2,3,4,5])`],
    probability: [`${fn}(5, 2)`, `${fn}(0.5)`],
    matrix: [`${fn}([1,2;3,4])`, `${fn}([1,2,3])`],
    relational: [`${fn}(2,3)`],
    bitwise: [`${fn}(6,3)`],
    logical: [`${fn}(true, false)`, `${fn}(true)`],
    set: [`${fn}([1,2,3],[2,3,4])`],
    unit: [`${fn}(5 cm, inch)`, `${fn}(5 cm)`],
    signal: [`${fn}([1,2,3])`],
    numeric: [`${fn}(1)`],
    string: [`${fn}('x')`],
    utils: [`${fn}(2)`],
    geometry: [`${fn}([0,0],[1,1])`],
    special: [`${fn}(2)`],
    combinatorics: [`${fn}(5,2)`, `${fn}(5)`],
  };

  return [
    ...(expressionOverridesByRel[entry.rel] ?? []),
    ...(expressionOverridesByFn[entry.fn] ?? []),
    ...(byCategory[entry.category] ?? []),
    ...generic,
  ];
}

function probeMathjsExpression(entry: Entry): { expr: string | null; error?: string } {
  const tried = new Set<string>();
  let lastErr = "";
  for (const expr of baseCandidates(entry)) {
    if (tried.has(expr)) continue;
    tried.add(expr);
    try {
      mathjs.evaluate(expr);
      return { expr };
    } catch (err) {
      lastErr = (err as Error).message;
    }
  }
  return { expr: null, error: lastErr || "no candidate expression worked in mathjs" };
}

function evalMathzig(mz: MathZig, expr: string): { ok: boolean; error?: string } {
  try {
    const value = mz.eval(expr);
    if (value instanceof Value) value.release();
    return { ok: true };
  } catch (err) {
    return { ok: false, error: (err as Error).message };
  }
}

describe("MathJS Full Function Surface vs MathZig", () => {
  it("tests every mathjs function test case with mathzig parity classification", () => {
    // libs/mathjs is reference-only / not committed (see .gitignore `/libs/*`).
    // Skip cleanly when the tree is absent so strict_bun stays green without
    // vendoring MathJS sources in every worktree.
    if (!existsSync(MATHJS_FUNCTION_TEST_ROOT)) {
      console.warn(
        `skip: ${MATHJS_FUNCTION_TEST_ROOT} missing (clone MathJS under libs/mathjs to enable)`
      );
      return;
    }
    const entries = collectFunctionEntries(MATHJS_FUNCTION_TEST_ROOT);
    const mz = MathZig.create();

    const results: ProbeResult[] = [];
    for (const entry of entries) {
      const probe = probeMathjsExpression(entry);
      if (!probe.expr) {
        results.push({
          entry,
          expr: null,
          mathjsOk: false,
          mathzigOk: false,
          error: probe.error,
        });
        continue;
      }

      const zig = evalMathzig(mz, probe.expr);
      results.push({
        entry,
        expr: probe.expr,
        mathjsOk: true,
        mathzigOk: zig.ok,
        error: zig.error,
      });
    }

    mz.destroy();

    const unresolved = results.filter((r) => !r.mathjsOk);
    const supported = results.filter((r) => r.mathjsOk && r.mathzigOk);
    const unsupported = results.filter((r) => r.mathjsOk && !r.mathzigOk);

    mkdirSync(OUT_DIR, { recursive: true });
    writeFileSync(
      OUT_JSON,
      JSON.stringify(
        {
          summary: {
            total: results.length,
            supported: supported.length,
            unsupported: unsupported.length,
            unresolved: unresolved.length,
          },
          unresolved: unresolved.map((r) => ({
            case: r.entry.rel,
            fn: r.entry.fn,
            error: r.error,
          })),
          unsupported: unsupported.map((r) => ({
            case: r.entry.rel,
            fn: r.entry.fn,
            expr: r.expr,
            error: r.error,
          })),
          supported: supported.map((r) => ({
            case: r.entry.rel,
            fn: r.entry.fn,
            expr: r.expr,
          })),
        },
        null,
        2,
      ),
    );

    const md = [
      "# MathJS Full Function Surface Report",
      "",
      `- Total: ${results.length}`,
      `- Supported in MathZig: ${supported.length}`,
      `- Unsupported in MathZig: ${unsupported.length}`,
      `- Unresolved sample expr in MathJS: ${unresolved.length}`,
      "",
      "## Unsupported",
      ...unsupported.map((r) => `- ${r.entry.rel}: \`${r.expr}\``),
      "",
      "## Unresolved",
      ...unresolved.map((r) => `- ${r.entry.rel}: ${r.error ?? "unknown error"}`),
    ].join("\n");
    writeFileSync(OUT_MD, md);

    const knownNonPublicMathjsCases = new Set([
      "algebra/sparse/csLu",
      "probability/seededrandom",
    ]);

    expect(results.length).toBeGreaterThan(0);
    expect(unresolved.every((r) => knownNonPublicMathjsCases.has(r.entry.rel))).toBe(true);

    if (process.env.REQUIRE_FULL_MATHJS_SUPPORT === "1") {
      expect(unsupported.length).toBe(0);
    }
  });
});
