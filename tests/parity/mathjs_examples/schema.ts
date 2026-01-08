export type ExampleTier = "core" | "extended" | "unsupported";

export type ExampleCategory =
  | "evaluate"
  | "translated"
  | "api"
  | "integration"
  | "symbolic"
  | "external"
  | "html_input";

export type NormalizedValue =
  | number
  | boolean
  | string
  | null
  | { __complex: true; re: number; im: number }
  | { __unit: true; value: number; unit?: string }
  | { __matrix: true; data: any }
  | { __error: true; message: string }
  | NormalizedValue[];

export type CompareMode = "value" | "assignment";

export interface ExampleCase {
  id: string;
  source: string;
  line: number;
  expr: string;
  tier: ExampleTier;
  category: ExampleCategory;
  setup: string[];
  preSetup?: string[];
  vars?: Record<string, number>;
  expected?: NormalizedValue;
  mathjsError?: string;
  reason?: string;
  tolerance?: number;
  compareMode?: CompareMode;
  hazard?: "crash";
}

/** One generated file per MathJS example source. */
export interface TranslatedExampleFile {
  source: string;
  slug: string;
  generatedAt: string;
  summary: {
    total: number;
    core: number;
    extended: number;
    unsupported: number;
  };
  cases: ExampleCase[];
}

export interface TranslatedIndex {
  generatedAt: string;
  files: Array<ExampleSourceSummary & { slug: string; path: string }>;
}

/** @deprecated Use per-file TranslatedExampleFile + TranslatedIndex */
export interface ExampleManifest {
  generatedAt: string;
  sources: ExampleSourceSummary[];
  cases: ExampleCase[];
}

export interface ExampleSourceSummary {
  source: string;
  total: number;
  core: number;
  extended: number;
  unsupported: number;
}

export interface ExampleRunResult {
  id: string;
  source: string;
  line: number;
  expr: string;
  tier: ExampleTier;
  status: "PASS" | "FAIL" | "SKIP" | "ERROR";
  reason?: string;
  expected?: NormalizedValue;
  actual?: NormalizedValue;
}

export interface ExampleRunSummary {
  generatedAt: string;
  tier: "all" | "core" | "extended";
  total: number;
  pass: number;
  fail: number;
  skip: number;
  error: number;
  results: ExampleRunResult[];
}