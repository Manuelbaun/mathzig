import { MathZig } from "../../../src/ts/mathzig";
import type { ParityBackend } from "../cli";

export class TsFfiBackend implements ParityBackend {
  name = "ts_ffi";
  private ctx: MathZig | null = null;

  init(): void {
    this.ctx = MathZig.create();
  }

  reset(): void {
    this.destroyCtx();
    this.ctx = MathZig.create();
  }

  evaluate(expr: string, vars: Record<string, number>): any {
    if (!this.ctx) throw new Error("backend not initialized");
    for (const [key, val] of Object.entries(vars)) {
      this.ctx.setVariable(key, val);
    }
    return this.ctx.eval(expr);
  }

  dispose(): void {
    this.destroyCtx();
  }

  private destroyCtx(): void {
    if (this.ctx) {
      try {
        // Ensure last exported value is scalar before tearing down this context.
        this.ctx.eval("0");
      } catch {
        // Ignore cleanup errors.
      }
      this.ctx.destroy();
      this.ctx = null;
    }
  }
}
