import type { ParityValue } from "../schema";

export interface BackendEvaluateResult {
  value: ParityValue;
  tag?: string;
  error?: string;
}

export interface ParityBackend {
  name: string;
  init(): Promise<void> | void;
  evaluate(expr: string, vars?: Record<string, number>): Promise<BackendEvaluateResult> | BackendEvaluateResult;
  dispose?(): Promise<void> | void;
}
