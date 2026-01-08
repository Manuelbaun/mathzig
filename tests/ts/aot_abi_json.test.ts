import { describe, expect, it } from "bun:test";
import { file } from "bun";

const ABI_PATH = "src/bindings/generated/aot_abi.json";

const SERIES_HANDLE_BASE = 1e9;
const RECORD_HANDLE_BASE = 1.5e9;
const MATRIX_HANDLE_BASE = 2e9;

describe("aot_abi.json", () => {
  it("matches abi.zig constants and sin signature", async () => {
    const abiFile = file(ABI_PATH);
    expect(await abiFile.exists()).toBe(true);

    const abi = await abiFile.json();

    expect(abi.abi_version).toBe(1);
    expect(abi.custom_section).toBe("mathzig.abi");
    expect(abi.handle_bases.series).toBe(SERIES_HANDLE_BASE);
    expect(abi.handle_bases.record).toBe(RECORD_HANDLE_BASE);
    expect(abi.handle_bases.matrix).toBe(MATRIX_HANDLE_BASE);

    const sin = abi.builtins.sin;
    expect(sin.args).toEqual(["number"]);
    expect(sin.ret).toBe("number");
    expect(sin.standalone_tier).toBe("scalar");
    expect(sin.supported).toBe(true);
  });
});