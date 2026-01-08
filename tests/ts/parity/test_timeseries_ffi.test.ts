import { expect, test, describe } from "bun:test";
import { MathZig, SampleMode } from "../../../src/ts/mathzig";

describe("MathZig Time-Series FFI", () => {
  test("Create and use series from TypeScript", () => {
    const mz = MathZig.create();

    const ts = new Float64Array([0, 10, 20, 30]);
    const vs = new Float64Array([100, 110, 120, 130]);

    const series = mz.createSeries(ts, vs, SampleMode.Linear);
    expect(series).toBeDefined();

    mz.setSeries("data", series.handle);

    const result = mz.eval("twa(data)");
    expect(result).toBe(115); // Average of 100, 110, 120, 130 linearly

    series.free();
    mz.destroy();
  });

  test("Series arithmetic in FFI", () => {
    const mz = MathZig.create();

    const s1 = mz.createSeries(new Float64Array([0, 20]), new Float64Array([10, 20]));
    const s2 = mz.createSeries(new Float64Array([10, 30]), new Float64Array([100, 200]));

    mz.setSeries("a", s1.handle);
    mz.setSeries("b", s2.handle);

    const result = mz.eval("twa(a + b)");
    expect(result).toBe(142.5);

    s1.free();
    s2.free();
    mz.destroy();
  });
});