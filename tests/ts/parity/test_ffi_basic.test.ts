import { expect, test, describe } from "bun:test";
import { MathZig, SampleMode } from "../../../src/ts/mathzig";

describe("MathZig FFI Basic", () => {
  test("Create and destroy context", () => {
    const mz = MathZig.create();
    expect(mz).toBeDefined();
    mz.destroy();
  });

  test("Version check", () => {
    const mz = MathZig.create();
    const v = mz.version();
    console.log("MathZig Version:", v);
    expect(v).toBeDefined();
    mz.destroy();
  });
});
