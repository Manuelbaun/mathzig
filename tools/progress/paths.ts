import * as fs from "node:fs";
import * as path from "node:path";

/** Repo root, anchored to this file (tools/progress/) — cwd-independent. */
export const ROOT = path.resolve(import.meta.dirname, "../..");

/** Override via PROGRESS_DIR env for tests / isolation. Absolute or ROOT-relative. */
export function resolveProgressDir(override?: string): string {
  const raw = override ?? process.env.PROGRESS_DIR ?? "tests/artifacts/progress";
  return path.isAbsolute(raw) ? raw : path.resolve(ROOT, raw);
}

export function getProgressPaths(progressDir?: string) {
  const PROGRESS_DIR = resolveProgressDir(progressDir);
  const PACKAGES_DIR = path.join(PROGRESS_DIR, "packages");
  const INDEX_FILE = path.join(PROGRESS_DIR, "index.json");
  return { PROGRESS_DIR, PACKAGES_DIR, INDEX_FILE };
}

/** Defaults for non-test CLI usage (respects PROGRESS_DIR). */
export const PROGRESS_DIR = resolveProgressDir();
export const PACKAGES_DIR = path.join(PROGRESS_DIR, "packages");
export const INDEX_FILE = path.join(PROGRESS_DIR, "index.json");

export const PARITY_ARTIFACTS_DIR = path.resolve(ROOT, "tests/artifacts/parity");
export const SNAPSHOTS_DIR = path.resolve(ROOT, "tests/artifacts/performance/snapshots");
export const PERF_LOG = path.resolve(ROOT, "tests/artifacts/performance/performance_log.csv");
export const VERSION_FILE = path.resolve(ROOT, "src/VERSION");
export const RUNS_DIR = path.resolve(ROOT, "tests/artifacts/runs");

/** Default static UI data dir (gitignored except .gitkeep). Override via CLI --out. */
export const DEFAULT_APP_DATA_DIR = path.resolve(ROOT, "apps/progress/public/data");

export function ensureProgressDirs(progressDir?: string): {
  PROGRESS_DIR: string;
  PACKAGES_DIR: string;
  INDEX_FILE: string;
} {
  const paths = getProgressPaths(progressDir);
  fs.mkdirSync(paths.PACKAGES_DIR, { recursive: true });
  return paths;
}
