# mathjs vs mathzig test coverage (function-level)

Compared **212** mathjs function test files (from `libs/mathjs/test/unit-tests/function/**`) against mathzig tests/cases in `tests/**`.

- Have: **103**
- Missing: **109**

## Coverage by category

| Category | Have | Missing | Total |
|---|---:|---:|---:|
| algebra | 2 | 19 | 21 |
| arithmetic | 27 | 10 | 37 |
| bitwise | 6 | 1 | 7 |
| combinatorics | 0 | 4 | 4 |
| complex | 4 | 0 | 4 |
| geometry | 0 | 2 | 2 |
| logical | 1 | 4 | 5 |
| matrix | 19 | 20 | 39 |
| numeric | 0 | 1 | 1 |
| probability | 8 | 5 | 13 |
| relational | 1 | 10 | 11 |
| set | 0 | 10 | 10 |
| signal | 0 | 2 | 2 |
| special | 1 | 1 | 2 |
| statistics | 10 | 3 | 13 |
| string | 1 | 1 | 2 |
| trigonometry | 20 | 5 | 25 |
| unit | 0 | 2 | 2 |
| utils | 3 | 9 | 12 |

## Missing in mathzig

- algebra/decomposition/lup
- algebra/decomposition/qr
- algebra/decomposition/schur
- algebra/decomposition/slu
- algebra/leafCount
- algebra/lyap
- algebra/polynomialRoot
- algebra/rationalize
- algebra/simplify
- algebra/simplifyConstant
- algebra/simplifyCore
- algebra/solver/lsolve
- algebra/solver/lsolveAll
- algebra/solver/lusolve
- algebra/solver/usolve
- algebra/solver/usolveAll
- algebra/sparse/csLu
- algebra/sylvester
- algebra/symbolicEqual
- arithmetic/addScalar
- arithmetic/createHypot
- arithmetic/dotDivide
- arithmetic/dotPow
- arithmetic/invmod
- arithmetic/nthRoots
- arithmetic/subtractScalar
- arithmetic/unaryMinus
- arithmetic/unaryPlus
- arithmetic/xgcd
- bitwise/rightLogShift
- combinatorics/bellNumbers
- combinatorics/catalan
- combinatorics/composition
- combinatorics/stirlingS2
- geometry/distance
- geometry/intersect
- logical/not
- logical/nullish
- logical/or
- logical/xor
- matrix/column
- matrix/concat
- matrix/ctranspose
- matrix/eigs
- matrix/expm
- matrix/fft
- matrix/ifft
- matrix/kron
- matrix/mapSlices
- matrix/matrixFrom
- matrix/partitionSelect
- matrix/pinv
- matrix/range
- matrix/resize
- matrix/rotate
- matrix/rotationMatrix
- matrix/sort
- matrix/sqrtm
- matrix/squeeze
- matrix/subset
- numeric/solveODE
- probability/bernoulli
- probability/combinationsWithRep
- probability/kldivergence
- probability/multinomial
- probability/seededrandom
- relational/compareNatural
- relational/compareText
- relational/deepEqual
- relational/equal
- relational/equalText
- relational/larger
- relational/largerEq
- relational/smaller
- relational/smallerEq
- relational/unequal
- set/setCartesian
- set/setDifference
- set/setDistinct
- set/setIntersect
- set/setIsSubset
- set/setMultiplicity
- set/setPowerset
- set/setSize
- set/setSymDifference
- set/setUnion
- signal/freqz
- signal/zpk2tf
- special/zeta
- statistics/corr
- statistics/mode
- statistics/quantileSeq
- string/print
- trigonometry/acos
- trigonometry/atan
- trigonometry/cosh
- trigonometry/sinh
- trigonometry/tanh
- unit/to
- unit/toBest
- utils/clone
- utils/hasNumericValue
- utils/isBounded
- utils/isNegative
- utils/isNumeric
- utils/isPositive
- utils/isPrime
- utils/isZero
- utils/typeof

## Covered in mathzig

- algebra/derivative (e.g. tests/scripts/csv_analysis.mzig:37:derivative(data.price))
- algebra/resolve (e.g. tests/ts/parity/parity_runner.test.ts:159:const reportPath = resolve("tests/artifacts/parity/parity_report.md");)
- arithmetic/abs (e.g. tests/parity/cases/complex.json:3:{ "id": "complex_abs_01", "expr": "abs(3 + 4i)", "vars": {}, "expected": { "tag": "number" }, "tolerance": 1e-12, "skip": ["ts_wasm_vm"] },)
- arithmetic/add (e.g. tests/parity/cases/dsl_functions.json:3:{ "id": "dsl_fn_02", "expr": "add(a, b) = a + b; add(5, 7)", "vars": {}, "expected": { "tag": "number" }, "tolerance": 0 },)
- arithmetic/cbrt (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:145:'cbrt(27)', 'cbrt(-8)',)
- arithmetic/ceil (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:137:'ceil(5.1)', 'ceil(-5.1)',)
- arithmetic/cube (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:147:'square(4)', 'cube(3)',)
- arithmetic/divide (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:172:{ expr: 'divide(10, 2)', zig: '10 / 2' },)
- arithmetic/dotMultiply (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:266:it('element-wise multiply', () => check('dotMultiply([1, 2], [3, 4])', { zigExpr: 'sum([1, 2] .* [3, 4])', todo: false }));)
- arithmetic/exp (e.g. tests/scripts/replay.mzig:23:exp(0)              # 1)
- arithmetic/expm1 (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:149:'log1p(0.5)', 'expm1(0.5)',)
- arithmetic/fix (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:148:'fix(5.9)', 'fix(-5.9)',)
- arithmetic/floor (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:138:'floor(5.9)', 'floor(-5.1)',)
- arithmetic/gcd (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:179:{ expr: 'gcd(12, 15)', zig: 'gcd(12, 15)' },)
- arithmetic/lcm (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:180:{ expr: 'lcm(12, 15)', zig: 'lcm(12, 15)' },)
- arithmetic/log (e.g. tests/scripts/replay.mzig:22:log(e)              # 1)
- arithmetic/log10 (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:87:expect(actual.re).toBeCloseTo(expected.re, -Math.log10(epsilon));)
- arithmetic/log1p (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:149:'log1p(0.5)', 'expm1(0.5)',)
- arithmetic/log2 (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:143:'log2(8)', 'log2(0.5)',)
- arithmetic/mod (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:176:{ expr: 'mod(10, 3)', zig: '10 % 3' },)
- arithmetic/multiply (e.g. tests/ts/parity/api_hardening.test.ts:60:const c = a.multiply(b, undefined);)
- arithmetic/norm (e.g. tests/scripts/replay.mzig:93:norm([3, 4])        # 5)
- arithmetic/nthRoot (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:185:{ expr: 'nthRoot(27, 3)', zig: 'nthRoot(27, 3)', approx: true },)
- arithmetic/pow (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:173:{ expr: 'pow(2, 3)', zig: '2 ^ 3' },)
- arithmetic/round (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:139:'round(5.5)', 'round(5.4)', 'round(-5.5)',)
- arithmetic/sign (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:146:'sign(-5)', 'sign(5)', 'sign(0)',)
- arithmetic/sqrt (e.g. tests/parity/mathjs_examples/cases/advanced/convert_fraction_to_bignumber.json:14:"expr": "sqrt(4)",)
- arithmetic/square (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:147:'square(4)', 'cube(3)',)
- arithmetic/subtract (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:170:{ expr: 'subtract(5, 2)', zig: '5 - 2' },)
- bitwise/bitAnd (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:296:it('bitAnd(6, 3)', () => check('bitAnd(6, 3)', { zigExpr: '6 & 3' }));)
- bitwise/bitNot (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:301:it('bitNot(6)', () => check('bitNot(6)', { zigExpr: '~6' }));)
- bitwise/bitOr (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:297:it('bitOr(6, 3)', () => check('bitOr(6, 3)', { zigExpr: '6 | 3' }));)
- bitwise/bitXor (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:298:it('bitXor(6, 3)', () => check('bitXor(6, 3)', { zigExpr: '6 ^^ 3' })); // Zig uses ^^? No, Zig parser uses caret_caret maps to bxor.)
- bitwise/leftShift (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:302:it('leftShift(2, 1)', () => check('leftShift(2, 1)', { zigExpr: '2 << 1' }));)
- bitwise/rightArithShift (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:303:it('rightArithShift(4, 1)', () => check('rightArithShift(4, 1)', { zigExpr: '4 >> 1' }));)
- complex/arg (e.g. tests/scripts/replay.mzig:35:arg(i)              # pi/2)
- complex/conj (e.g. tests/scripts/replay.mzig:33:conj(10 + i)        # 10 - i)
- complex/im (e.g. tests/scripts/complex_test.mzig:6:assert(im(z3), 6))
- complex/re (e.g. tests/scripts/complex_test.mzig:5:assert(re(z3), 4))
- logical/and (e.g. tests/ts/parity/wasm_memory.test.ts:38:const { result } = await compileAndRun("(M1 = [1, 2]) and (M2 = [3, 4]) and (M1[0, 0] + M2[0, 1])");)
- matrix/count (e.g. tests/scripts/csv_analysis.mzig:42:count(data.price) where value > 160)
- matrix/cross (e.g. tests/ts/parity/matrix.test.ts:118:const result = mathzig.eval('cross([1, 0, 0], [0, 1, 0])');)
- matrix/det (e.g. tests/parity/cases/matrix_ops_extended.json:3:{ "id": "matrix_det_01", "expr": "det([1, 2; 3, 4])", "vars": {}, "expected": { "tag": "number" }, "tolerance": 1e-9, "skip": ["ts_wasm_vm"] },)
- matrix/diag (e.g. tests/scripts/replay.mzig:92:diag(A)             # [1; 4])
- matrix/diff (e.g. tests/scripts/replay.mzig:125:diff(S1, 1))
- matrix/dot (e.g. tests/scripts/replay.mzig:84:dot([1, 2, 3], [4, 5, 6]) # 32)
- matrix/filter (e.g. tests/ts/parity/parity_runner.test.ts:163:const failed = results.filter((r) => r.status === "FAIL");)
- matrix/flatten (e.g. tests/scripts/replay.mzig:96:flatten(A)          # 4x1)
- matrix/forEach (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:158:unaryTests.forEach(expr => {)
- matrix/identity (e.g. tests/scripts/replay.mzig:98:identity(3))
- matrix/inv (e.g. tests/scripts/replay.mzig:88:inv([4, 7; 2, 6]))
- matrix/map (e.g. tests/ts/simulations/rocket_simulation/full-simulation.test.ts:110:const deriv = funcs.map((fn: any) => fn(...current));)
- matrix/ones (e.g. tests/scripts/replay.mzig:100:ones(1, 5))
- matrix/reshape (e.g. tests/scripts/replay.mzig:97:reshape([1, 2, 3, 4, 5, 6], 2, 3))
- matrix/row (e.g. tests/ts/simulations/rocket_simulation/integration/ode-basic.test.ts:242:console.log("First row (t=0):");)
- matrix/size (e.g. tests/scripts/replay.mzig:91:size(A))
- matrix/trace (e.g. tests/parity/cases/matrix_ops_extended.json:2:{ "id": "matrix_trace_01", "expr": "trace([1, 2; 3, 4])", "vars": {}, "expected": { "tag": "number" }, "tolerance": 1e-12, "skip": ["ts_wasm_vm"] },)
- matrix/transpose (e.g. tests/scripts/replay.mzig:89:transpose(A))
- matrix/zeros (e.g. tests/parity/mathjs_examples/cases/expressions.json:152:"expr": "l = zeros(2, 2)",)
- probability/combinations (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:183:{ expr: 'combinations(5, 2)', zig: 'combinations(5, 2)' },)
- probability/factorial (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:288:it('factorial(5)', () => check('factorial(5)'));)
- probability/gamma (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:155:'erf(0.5)', 'gamma(1.5)', 'lgamma(1.5)',)
- probability/lgamma (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:155:'erf(0.5)', 'gamma(1.5)', 'lgamma(1.5)',)
- probability/permutations (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:184:{ expr: 'permutations(5, 2)', zig: 'permutations(5, 2)' },)
- probability/pickRandom (e.g. tests/ts/parity/probability.test.ts:59:const val = evalNum('pickRandom([10, 20, 30])');)
- probability/random (e.g. tests/parity/cases/probability.json:2:{ "id": "prob_random_01", "expr": "random(10.0)", "vars": {}, "expected": { "type": "any" }, "tolerance": 0, "skip": ["ts_wasm_vm"], "note": "requires fixed RNG seed" },)
- probability/randomInt (e.g. tests/parity/cases/probability.json:3:{ "id": "prob_randint_01", "expr": "randomInt(5, 15)", "vars": {}, "expected": { "type": "any" }, "tolerance": 0, "skip": ["ts_wasm_vm"], "note": "requires fixed RNG seed" })
- relational/compare (e.g. tests/ts/parity/comparison_mathjs_parity.test.ts:74:const { valJS, valZig } = compare('1 + 2 * 3 / 4', { iterations: 1000, useWarm: true });)
- special/erf (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:155:'erf(0.5)', 'gamma(1.5)', 'lgamma(1.5)',)
- statistics/cumsum (e.g. tests/scripts/csv_analysis.mzig:32:cumsum(data.price))
- statistics/mad (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:289:it('mad', () => check(`mad(${list})`));)
- statistics/max (e.g. tests/parity/cases/timeseries_stats.json:20:"expr": "max(series([1, 2, 3], [10, 5, 30]))",)
- statistics/mean (e.g. tests/parity/cases/timeseries_filters.json:20:"expr": "mean(series([1, 2, 3, 4], [10, -5, 20, -3])) where value > 0",)
- statistics/median (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:283:it('median', () => check(`median(${list})`));)
- statistics/min (e.g. tests/parity/cases/timeseries_stats.json:12:"expr": "min(series([1, 2, 3], [10, 5, 30]))",)
- statistics/prod (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:286:it('prod', () => check(`prod(${list})`));)
- statistics/std (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:284:it('std', () => check(`std(${list})`, { epsilon: 1e-4 }));)
- statistics/sum (e.g. tests/parity/cases/matrix_ops_extended.json:4:{ "id": "matrix_sum_01", "expr": "sum([1, 2; 3, 4])", "vars": {}, "expected": { "tag": "number" }, "tolerance": 1e-12, "skip": ["ts_wasm_vm"] })
- statistics/variance (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:285:it('variance', () => check(`variance(${list})`));)
- string/format (e.g. tests/ts/simulations/rocket_simulation/full-simulation.test.ts:35:const formatted = mz.eval(`"${expr} = " + format(${expr})`);)
- trigonometry/acosh (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:150:'asinh(0.5)', 'acosh(1.5)', 'atanh(0.5)',)
- trigonometry/acot (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:152:'asec(1.5)', 'acsc(1.5)', 'acot(0.5)',)
- trigonometry/acoth (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:154:'asech(0.5)', 'acsch(0.5)', 'acoth(1.5)',)
- trigonometry/acsc (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:152:'asec(1.5)', 'acsc(1.5)', 'acot(0.5)',)
- trigonometry/acsch (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:154:'asech(0.5)', 'acsch(0.5)', 'acoth(1.5)',)
- trigonometry/asec (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:152:'asec(1.5)', 'acsc(1.5)', 'acot(0.5)',)
- trigonometry/asech (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:154:'asech(0.5)', 'acsch(0.5)', 'acoth(1.5)',)
- trigonometry/asin (e.g. tests/zig/config.test.zig:25:const res3 = try ctx.eval("asin(1)");)
- trigonometry/asinh (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:150:'asinh(0.5)', 'acosh(1.5)', 'atanh(0.5)',)
- trigonometry/atan2 (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:181:{ expr: 'atan2(1, 1)', zig: 'atan2(1, 1)' },)
- trigonometry/atanh (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:150:'asinh(0.5)', 'acosh(1.5)', 'atanh(0.5)',)
- trigonometry/cos (e.g. tests/parity/mathjs_examples/cases/expressions.json:40:"expr": "cos(45 deg)",)
- trigonometry/cot (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:151:'sec(0.5)', 'csc(0.5)', 'cot(0.5)',)
- trigonometry/coth (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:153:'sech(0.5)', 'csch(0.5)', 'coth(0.5)',)
- trigonometry/csc (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:151:'sec(0.5)', 'csc(0.5)', 'cot(0.5)',)
- trigonometry/csch (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:153:'sech(0.5)', 'csch(0.5)', 'coth(0.5)',)
- trigonometry/sec (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:151:'sec(0.5)', 'csc(0.5)', 'cot(0.5)',)
- trigonometry/sech (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:153:'sech(0.5)', 'csch(0.5)', 'coth(0.5)',)
- trigonometry/sin (e.g. tests/parity/cases/core_arithmetic.json:25:"expr": "sin(pi / 2)",)
- trigonometry/tan (e.g. tests/ts/parity/compiler.test.ts:159:res = mathzig.eval('tan(0)');)
- utils/isFinite (e.g. tests/ts/parity/integration.test.ts:152:expect(isNaN(val) || !isFinite(val)).toBe(true);)
- utils/isInteger (e.g. tests/ts/parity/comparison_mathjs_comprehensive.test.ts:114:if (options.approx || !Number.isInteger(expected)) {)
- utils/isNaN (e.g. tests/ts/parity/ffi_boundary_validation.test.ts:470:expect(Number.isNaN(result.toNumber())).toBe(true);)
