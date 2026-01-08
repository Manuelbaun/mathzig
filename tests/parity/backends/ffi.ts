import { MathZig } from "../../../src/ts/mathzig";
import type { ParityBackend, BackendEvaluateResult } from "./types";

export function createFfiBackend(): ParityBackend {
  let mz: MathZig | null = null;

  return {
    name: "ffi",
    async init() {
      mz = MathZig.create();
    },
    evaluate(expr: string, vars?: Record<string, number>): BackendEvaluateResult {
      if (!mz) throw new Error("FFI backend not initialized");
      try {
        if (vars) {
          for (const [key, value] of Object.entries(vars)) {
            mz.setVariable(key, value);
          }
        }
        const value = mz.eval(expr);
        return { value };
      } catch (error) {
        return { value: undefined, error: error instanceof Error ? error.message : String(error) };
      }
    },
    dispose() {
      if (mz) {
        mz.destroy();
        mz = null;
      }
    },
  };
}
