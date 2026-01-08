// AUTO-GENERATED from src/bindings/generated/aot_abi.json — do not edit.
import type { AotHostEnv } from "../../ts/aot_env";

export type GeneratedAotStub = (...args: number[]) => number;

const FAST_SCALAR: Record<string, GeneratedAotStub> = {
  pow: Math.pow,
  fmod: (a: number, b: number) => a - Math.abs(b) * Math.floor(a / Math.abs(b)),
  abs: (x: number) => Math.abs(x),
  cbrt: (Math as any).cbrt,
  exp: (Math as any).exp,
  log10: (Math as any).log10,
  log2: (Math as any).log2,
  sin: (Math as any).sin,
  cos: (Math as any).cos,
  tan: (Math as any).tan,
  asin: (Math as any).asin,
  acos: (Math as any).acos,
  atan: (Math as any).atan,
  atan2: (Math as any).atan2,
  sinh: (Math as any).sinh,
  cosh: (Math as any).cosh,
  tanh: (Math as any).tanh,
  floor: (Math as any).floor,
  ceil: (Math as any).ceil,
  sign: (Math as any).sign,
  hypot: (Math as any).hypot,
  log1p: (Math as any).log1p,
  expm1: (Math as any).expm1,
  asinh: (Math as any).asinh,
  acosh: (Math as any).acosh,
  atanh: (Math as any).atanh,
};

export function buildGeneratedAotStubs(host: AotHostEnv): Record<string, GeneratedAotStub> {
  const stubs: Record<string, GeneratedAotStub> = { ...FAST_SCALAR };
  stubs["abs"] = (...args: number[]) => host.callDelegated("abs", args);
  stubs["sqrt"] = (...args: number[]) => host.callDelegated("sqrt", args);
  stubs["log"] = (...args: number[]) => host.callDelegated("log", args);
  stubs["sec"] = (...args: number[]) => host.callDelegated("sec", args);
  stubs["csc"] = (...args: number[]) => host.callDelegated("csc", args);
  stubs["cot"] = (...args: number[]) => host.callDelegated("cot", args);
  stubs["asec"] = (...args: number[]) => host.callDelegated("asec", args);
  stubs["acsc"] = (...args: number[]) => host.callDelegated("acsc", args);
  stubs["acot"] = (...args: number[]) => host.callDelegated("acot", args);
  stubs["round"] = (...args: number[]) => host.callDelegated("round", args);
  stubs["trunc"] = (...args: number[]) => host.callDelegated("trunc", args);
  stubs["min"] = (...args: number[]) => host.callDelegated("min", args);
  stubs["min_where"] = (...args: number[]) => host.callDelegated("min", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["max"] = (...args: number[]) => host.callDelegated("max", args);
  stubs["max_where"] = (...args: number[]) => host.callDelegated("max", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["clamp"] = (...args: number[]) => host.callDelegated("clamp", args);
  stubs["norm"] = (...args: number[]) => host.callDelegated("norm", args);
  stubs["random"] = (...args: number[]) => host.callDelegated("random", args);
  stubs["randomInt"] = (...args: number[]) => host.callDelegated("randomInt", args);
  stubs["pickRandom"] = (...args: number[]) => host.callDelegated("pickRandom", args);
  stubs["square"] = (...args: number[]) => host.callDelegated("square", args);
  stubs["cube"] = (...args: number[]) => host.callDelegated("cube", args);
  stubs["nthRoot"] = (...args: number[]) => host.callDelegated("nthRoot", args);
  stubs["sech"] = (...args: number[]) => host.callDelegated("sech", args);
  stubs["csch"] = (...args: number[]) => host.callDelegated("csch", args);
  stubs["coth"] = (...args: number[]) => host.callDelegated("coth", args);
  stubs["asech"] = (...args: number[]) => host.callDelegated("asech", args);
  stubs["acsch"] = (...args: number[]) => host.callDelegated("acsch", args);
  stubs["acoth"] = (...args: number[]) => host.callDelegated("acoth", args);
  stubs["factorial"] = (...args: number[]) => host.callDelegated("factorial", args);
  stubs["gamma"] = (...args: number[]) => host.callDelegated("gamma", args);
  stubs["lgamma"] = (...args: number[]) => host.callDelegated("lgamma", args);
  stubs["erf"] = (...args: number[]) => host.callDelegated("erf", args);
  stubs["combinations"] = (...args: number[]) => host.callDelegated("combinations", args);
  stubs["permutations"] = (...args: number[]) => host.callDelegated("permutations", args);
  stubs["re"] = (...args: number[]) => host.callDelegated("re", args);
  stubs["im"] = (...args: number[]) => host.callDelegated("im", args);
  stubs["arg"] = (...args: number[]) => host.callDelegated("arg", args);
  stubs["conj"] = (...args: number[]) => host.callDelegated("conj", args);
  stubs["det"] = (...args: number[]) => host.callDelegated("det", args);
  stubs["inv"] = (...args: number[]) => host.callDelegated("inv", args);
  stubs["transpose"] = (...args: number[]) => host.callDelegated("transpose", args);
  stubs["gemv"] = (...args: number[]) => host.callDelegated("gemv", args);
  stubs["size"] = (...args: number[]) => host.callDelegated("size", args);
  stubs["trace"] = (...args: number[]) => host.callDelegated("trace", args);
  stubs["dot"] = (...args: number[]) => host.callDelegated("dot", args);
  stubs["cross"] = (...args: number[]) => host.callDelegated("cross", args);
  stubs["reshape"] = (...args: number[]) => host.callDelegated("reshape", args);
  stubs["flatten"] = (...args: number[]) => host.callDelegated("flatten", args);
  stubs["concat"] = (...args: number[]) => host.callDelegated("concat", args);
  stubs["diag"] = (...args: number[]) => host.callDelegated("diag", args);
  stubs["identity"] = (...args: number[]) => host.callDelegated("identity", args);
  stubs["zeros"] = (...args: number[]) => host.callDelegated("zeros", args);
  stubs["ones"] = (...args: number[]) => host.callDelegated("ones", args);
  stubs["mean"] = (...args: number[]) => host.callDelegated("mean", args);
  stubs["mean_where"] = (...args: number[]) => host.callDelegated("mean", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["sum"] = (...args: number[]) => host.callDelegated("sum", args);
  stubs["sum_where"] = (...args: number[]) => host.callDelegated("sum", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["count"] = (...args: number[]) => host.callDelegated("count", args);
  stubs["count_where"] = (...args: number[]) => host.callDelegated("count", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["median"] = (...args: number[]) => host.callDelegated("median", args);
  stubs["median_where"] = (...args: number[]) => host.callDelegated("median", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["std"] = (...args: number[]) => host.callDelegated("std", args);
  stubs["std_where"] = (...args: number[]) => host.callDelegated("std", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["variance"] = (...args: number[]) => host.callDelegated("variance", args);
  stubs["variance_where"] = (...args: number[]) => host.callDelegated("variance", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["mad"] = (...args: number[]) => host.callDelegated("mad", args);
  stubs["mad_where"] = (...args: number[]) => host.callDelegated("mad", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["prod"] = (...args: number[]) => host.callDelegated("prod", args);
  stubs["prod_where"] = (...args: number[]) => host.callDelegated("prod", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["gcd"] = (...args: number[]) => host.callDelegated("gcd", args);
  stubs["lcm"] = (...args: number[]) => host.callDelegated("lcm", args);
  stubs["isPrime"] = (...args: number[]) => host.callDelegated("isPrime", args);
  stubs["conv"] = (...args: number[]) => host.callDelegated("conv", args);
  stubs["number"] = (...args: number[]) => host.callDelegated("number", args);
  stubs["read_csv"] = (...args: number[]) => host.callDelegated("read_csv", args);
  stubs["assert"] = (...args: number[]) => host.callDelegated("assert", args);
  stubs["cumsum"] = (...args: number[]) => host.callDelegated("cumsum", args);
  stubs["cummax"] = (...args: number[]) => host.callDelegated("cummax", args);
  stubs["cummin"] = (...args: number[]) => host.callDelegated("cummin", args);
  stubs["rolling_sum"] = (...args: number[]) => host.callDelegated("rolling_sum", args);
  stubs["rolling_mean"] = (...args: number[]) => host.callDelegated("rolling_mean", args);
  stubs["rolling_min"] = (...args: number[]) => host.callDelegated("rolling_min", args);
  stubs["rolling_max"] = (...args: number[]) => host.callDelegated("rolling_max", args);
  stubs["rolling_count"] = (...args: number[]) => host.callDelegated("rolling_count", args);
  stubs["rolling_stddev"] = (...args: number[]) => host.callDelegated("rolling_stddev", args);
  stubs["diff"] = (...args: number[]) => host.callDelegated("diff", args);
  stubs["pct_change"] = (...args: number[]) => host.callDelegated("pct_change", args);
  stubs["series"] = (...args: number[]) => host.callDelegated("series", args);
  stubs["twa"] = (...args: number[]) => host.callDelegated("twa", args);
  stubs["twa_where"] = (...args: number[]) => host.callDelegated("twa", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["derivative"] = (...args: number[]) => host.callDelegated("derivative", args);
  stubs["integrate"] = (...args: number[]) => host.callDelegated("integrate", args);
  stubs["sma"] = (...args: number[]) => host.callDelegated("sma", args);
  stubs["ema"] = (...args: number[]) => host.callDelegated("ema", args);
  stubs["rsi"] = (...args: number[]) => host.callDelegated("rsi", args);
  stubs["last"] = (...args: number[]) => host.callDelegated("last", args);
  stubs["duration"] = (...args: number[]) => host.callDelegated("duration", args);
  stubs["duration_where"] = (...args: number[]) => host.callDelegated("duration", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["asofJoin"] = (...args: number[]) => host.callDelegated("asofJoin", args);
  stubs["resample"] = (...args: number[]) => host.callDelegated("resample", args);
  stubs["align_"] = (...args: number[]) => host.callDelegated("align_", args);
  stubs["head"] = (...args: number[]) => host.callDelegated("head", args);
  stubs["tail"] = (...args: number[]) => host.callDelegated("tail", args);
  stubs["slice"] = (...args: number[]) => host.callDelegated("slice", args);
  stubs["between"] = (...args: number[]) => host.callDelegated("between", args);
  stubs["since"] = (...args: number[]) => host.callDelegated("since", args);
  stubs["shift"] = (...args: number[]) => host.callDelegated("shift", args);
  stubs["dropna"] = (...args: number[]) => host.callDelegated("dropna", args);
  stubs["fillna"] = (...args: number[]) => host.callDelegated("fillna", args);
  stubs["clip"] = (...args: number[]) => host.callDelegated("clip", args);
  stubs["bollinger"] = (...args: number[]) => host.callDelegated("bollinger", args);
  stubs["macd"] = (...args: number[]) => host.callDelegated("macd", args);
  stubs["gen_range"] = (...args: number[]) => host.callDelegated("gen_range", args);
  stubs["linspace"] = (...args: number[]) => host.callDelegated("linspace", args);
  stubs["logspace"] = (...args: number[]) => host.callDelegated("logspace", args);
  stubs["agg_range"] = (...args: number[]) => host.callDelegated("agg_range", args);
  stubs["agg_range_where"] = (...args: number[]) => host.callDelegated("agg_range", args.slice(0, -1), args[args.length - 1] ?? 0);
  stubs["now"] = (...args: number[]) => host.callDelegated("now", args);
  stubs["ode_solve"] = (...args: number[]) => host.callDelegated("ode_solve", args);
  stubs["ode_solve_euler"] = (...args: number[]) => host.callDelegated("ode_solve_euler", args);
  stubs["toLaTeX"] = (...args: number[]) => host.callDelegated("toLaTeX", args);
  return stubs;
}
