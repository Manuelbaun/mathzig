import { test } from "bun:test";
import { runMathZigCompiler } from "../wasm_utils";

test("Inspect Bytecode", async () => {
    const code = `
    x = 0;
    while (x < 10) {
        x = x + 1
    };
    x
    `;
    await runMathZigCompiler(code, 0);
});