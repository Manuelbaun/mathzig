import type { ParityBackend, BackendEvaluateResult } from "./types";

export function createNativeBackend(): ParityBackend {
  return {
    name: "native",
    async init() {
      throw new Error("Native backend not implemented yet");
    },
    evaluate(): BackendEvaluateResult {
      throw new Error("Native backend not implemented yet");
    },
  };
}
