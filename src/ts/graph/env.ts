export type ScalarWasmEnv = Record<string, (...args: number[]) => number>;

export type ScalarWasmImports = Record<string, Record<string, (...args: number[]) => number>>;

export function createDefaultScalarWasmEnv(overrides: Partial<ScalarWasmEnv> = {}): ScalarWasmEnv {
  return {
    pow: Math.pow,
    // Euclidean modulo (result in [0, |b|)) — must match the VM's
    // euclideanMod and the standalone generateFmodBody, not JS `%`
    // (sign of dividend).
    fmod: (a: number, b: number) => a - Math.abs(b) * Math.floor(a / Math.abs(b)),
    sin: Math.sin,
    cos: Math.cos,
    tan: Math.tan,
    asin: Math.asin,
    acos: Math.acos,
    atan: Math.atan,
    atan2: Math.atan2,
    sqrt: (x: number, n?: number) => (n === undefined ? Math.sqrt(x) : Math.pow(x, 1 / n)),
    cbrt: Math.cbrt,
    exp: Math.exp,
    log: (x: number, base?: number) => (base === undefined ? Math.log(x) : Math.log(x) / Math.log(base)),
    log10: Math.log10,
    log2: Math.log2,
    log1p: Math.log1p,
    expm1: Math.expm1,
    abs: Math.abs,
    floor: Math.floor,
    ceil: Math.ceil,
    // Half away from zero, matching Zig @round (Math.round is half toward +∞:
    // Math.round(-0.5) === -0, @round(-0.5) === -1).
    round: (x: number) => Math.sign(x) * Math.round(Math.abs(x)),
    sign: Math.sign,
    min: Math.min,
    max: Math.max,
    hypot: Math.hypot,
    square: (x: number) => x * x,
    cube: (x: number) => x * x * x,
    nthRoot: (x: number, n: number) => Math.pow(x, 1 / n),
    sec: (x: number) => 1 / Math.cos(x),
    csc: (x: number) => 1 / Math.sin(x),
    cot: (x: number) => 1 / Math.tan(x),
    sinh: Math.sinh,
    cosh: Math.cosh,
    tanh: Math.tanh,
    asinh: Math.asinh,
    acosh: Math.acosh,
    atanh: Math.atanh,
    clamp: (value: number, min: number, max: number) => Math.max(min, Math.min(max, value)),
    ...overrides,
  };
}

export function createDefaultScalarWasmImports(overrides: Partial<ScalarWasmEnv> = {}): ScalarWasmImports {
  return { env: createDefaultScalarWasmEnv(overrides) };
}
