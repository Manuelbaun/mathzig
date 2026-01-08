import { describe, expect, it } from "bun:test";
import aotAbi from "../../src/bindings/generated/aot_abi.json";

describe("aot_abi.json", () => {
  it("matches abi.zig handle bases and sin signature", () => {
    expect(aotAbi.abi_version).toBe(1);
    expect(aotAbi.custom_section).toBe("mathzig.abi");
    expect(aotAbi.handle_bases.series).toBe(1e9);
    expect(aotAbi.handle_bases.record).toBe(1.5e9);
    expect(aotAbi.handle_bases.matrix).toBe(2e9);
    const sin = (aotAbi.builtins as Record<string, any>).sin;
    expect(sin.args).toEqual(["number"]);
    expect(sin.ret).toBe("number");
    expect(sin.supported).toBe(true);
    expect(sin.fast_scalar).toBe(true);
  });
});