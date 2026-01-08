import type { ParityBackend, BackendEvaluateResult } from "./types";

export function createWasmVmBackend(): ParityBackend {
  return {
    name: "wasm_vm",
    async init() {
      throw new Error("WASM VM backend not implemented yet");
    },
    evaluate(): BackendEvaluateResult {
      throw new Error("WASM VM backend not implemented yet");
    },
  };
}
