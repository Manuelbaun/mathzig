export const ValueTag = {
  number: 0,
  complex: 1,
  unit: 2,
  matrix: 3,
  series: 4,
  predicate: 5,
  string: 6,
  boolean: 7,
  function: 8,
  array: 9,
  record: 10,
  slice: 11,
  undefined: 12,
  null_val: 13,
  err: 14,
} as const;

export type ValueTagId = (typeof ValueTag)[keyof typeof ValueTag];

export const TagNames: Record<number, string> = {
  0: "number",
  1: "complex",
  2: "unit",
  3: "matrix",
  4: "series",
  5: "predicate",
  6: "string",
  7: "boolean",
  8: "function",
  9: "array",
  10: "record",
  11: "slice",
  12: "undefined",
  13: "null",
  14: "error",
};

export type EvalResult = {
  error?: string;
  value?: string;
  type?: string;
  tag?: number;
  ptr?: number;
  number?: number;
  re?: number;
  im?: number;
  assignName?: string;
  latex?: string | null;
  renderLatex?: boolean;
  seriesData?: { len: number; timestamps: number[]; values: number[] };
  data?: number[];
};

export type VarEntry = {
  value: string;
  type: string;
  tag: number;
  number?: number;
  ptr?: number;
  re?: number;
  im?: number;
  seriesData?: { len: number; timestamps: number[]; values: number[] };
  data?: number[];
};
