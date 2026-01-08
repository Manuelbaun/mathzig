import type { WasmCompiler } from "@mathzig/graph";

/**
 * Browser WasmCompiler: posts expr text to the console Vite middleware
 * (`/api/aot_compile`), which shells out to `zig-out/bin/mathzig compile`.
 */
export function createBrowserAotCompiler(version = "console-graph"): WasmCompiler {
  return {
    version,
    async compile(expr: string, numParams: number): Promise<Uint8Array> {
      const res = await fetch(`/api/aot_compile?params=${encodeURIComponent(String(numParams))}`, {
        method: "POST",
        headers: { "content-type": "text/plain;charset=utf-8" },
        body: expr,
      });
      if (!res.ok) {
        const msg = await res.text();
        throw new Error(msg || `AOT compile failed (HTTP ${res.status})`);
      }
      return new Uint8Array(await res.arrayBuffer());
    },
  };
}
