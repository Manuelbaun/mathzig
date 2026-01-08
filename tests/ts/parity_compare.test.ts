import { expect, test } from "bun:test";
import { compareValue } from "../parity/compare";

test("compareValue numbers within tolerance", () => {
  expect(compareValue(1, 1 + 1e-13)).toBe(true);
  expect(compareValue(1, 1 + 1e-6)).toBe(false);
});

test("compareValue arrays", () => {
  expect(compareValue([1, 2], [1, 2])).toBe(true);
  expect(compareValue([1, 2], [1, 3])).toBe(false);
});

test("compareValue records", () => {
  expect(compareValue({ a: 1, b: 2 }, { b: 2, a: 1 })).toBe(true);
  expect(compareValue({ a: 1 }, { a: 2 })).toBe(false);
});

test("compareValue NaN/undefined policy", () => {
  expect(compareValue(undefined, NaN, { treatNaNAsUndefined: true })).toBe(true);
  expect(compareValue(undefined, NaN, { treatNaNAsUndefined: false })).toBe(false);
});
