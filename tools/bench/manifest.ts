import * as fs from "node:fs";
import * as path from "node:path";

export type BenchDef = {
  id: string;
  suite: string;
  description: string;
  unit: string;
  higher_is_better: boolean;
  regression_threshold_pct: number;
  aliases: string[];
};

export type BenchManifest = {
  version: number;
  tiers: Record<string, string[]>;
  benchmarks: BenchDef[];
  backend_from_test_name: Array<{ prefix: string; backend: string; strip_prefix: boolean }>;
  thread_suffix_pattern: string;
};

const MANIFEST_PATH = path.resolve(process.cwd(), "bench/manifest.json");

let cached: BenchManifest | null = null;

export function loadManifest(): BenchManifest {
  if (cached) return cached;
  cached = JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf8")) as BenchManifest;
  return cached;
}

export function tierBenchIds(tier: string): Set<string> | null {
  const manifest = loadManifest();
  const ids = manifest.tiers[tier];
  if (!ids) return null;
  if (ids.includes("*")) return null;
  return new Set(ids);
}

export function resolveBenchId(testName: string): string {
  const manifest = loadManifest();
  const threadRe = new RegExp(manifest.thread_suffix_pattern);
  const base = testName.replace(threadRe, "");

  for (const bench of manifest.benchmarks) {
    if (bench.aliases.includes(base)) return bench.id;
    for (const alias of bench.aliases) {
      if (alias.endsWith("_") && base.startsWith(alias)) return bench.id;
    }
  }
  return base;
}

export function resolveBackend(testName: string): string {
  const manifest = loadManifest();
  for (const rule of manifest.backend_from_test_name) {
    if (testName.startsWith(rule.prefix)) return rule.backend;
  }
  return "unknown";
}

export function resolveThreads(testName: string): number {
  const manifest = loadManifest();
  const threadRe = new RegExp(manifest.thread_suffix_pattern);
  const m = testName.match(threadRe);
  if (!m) return 1;
  return Number(m[1]) || 1;
}

export function benchById(id: string): BenchDef | undefined {
  return loadManifest().benchmarks.find((b) => b.id === id);
}