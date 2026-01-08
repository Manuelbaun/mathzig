import { describe, expect, test } from "bun:test";
import { ValueTag } from "../engine/value_tags";
import { buildSuggestItems } from "./autocomplete_catalog";

describe("buildSuggestItems", () => {
  test("prefers variables matching query", () => {
    const items = buildSuggestItems("demo", {
      demo_data: {
        value: "[Series: 50]",
        type: "series",
        tag: ValueTag.series,
      },
      x: { value: "1", type: "number", tag: ValueTag.number },
    });
    expect(items.length).toBeGreaterThan(0);
    expect(items[0]!.label).toBe("demo_data");
    expect(items[0]!.kind).toBe("variable");
  });

  test("matches commands and snippets by prefix", () => {
    const items = buildSuggestItems("plot", {});
    const labels = items.map((i) => i.insert);
    expect(labels.some((l) => l.startsWith("plot"))).toBe(true);
  });

  test("includes constants for pi", () => {
    const items = buildSuggestItems("pi", {});
    expect(items.some((i) => i.insert === "pi" && i.kind === "constant")).toBe(true);
  });

  test("returns empty for nonsense query", () => {
    const items = buildSuggestItems("zzzznotreal", {});
    expect(items).toEqual([]);
  });
});
