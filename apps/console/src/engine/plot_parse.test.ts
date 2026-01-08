import { describe, expect, it } from "bun:test";
import { buildPlotSeries, splitArgs } from "./plot_parse";
import { ValueTag, type VarEntry } from "./value_tags";

describe("plot_parse", () => {
  it("splits nested array args", () => {
    expect(splitArgs("[1,2], [3,4]")).toEqual(["[1,2]", "[3,4]"]);
  });

  it("builds multi-array plot", () => {
    const vars: Record<string, VarEntry> = {};
    const built = buildPlotSeries(
      "[1,2,3], [2,3,5]",
      vars,
      () => null,
      () => null,
    );
    expect("error" in built).toBe(false);
    if ("error" in built) return;
    expect(built.x).toEqual([1, 2, 3]);
    expect(built.ys).toEqual([[2, 3, 5]]);
  });

  it("plots series var", () => {
    const vars: Record<string, VarEntry> = {
      demo_data: {
        value: "[Series: 3]",
        type: "series",
        tag: ValueTag.series,
        ptr: 1,
      },
    };
    const built = buildPlotSeries(
      "demo_data",
      vars,
      () => ({ timestamps: [0, 1, 2], values: [1, 2, 3] }),
      () => null,
    );
    expect("error" in built).toBe(false);
    if ("error" in built) return;
    expect(built.title).toBe("demo_data");
    expect(built.x).toEqual([0, 1, 2]);
    expect(built.ys[0]).toEqual([1, 2, 3]);
  });
});
