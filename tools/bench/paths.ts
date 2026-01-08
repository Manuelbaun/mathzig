import * as fs from "node:fs";
import * as path from "node:path";

export const ROOT = process.cwd();
export const PERF_DIR = path.resolve(ROOT, "tests/artifacts/performance");
export const PERF_LOG = path.join(PERF_DIR, "performance_log.csv");
export const SNAPSHOTS_DIR = path.join(PERF_DIR, "snapshots");
export const INDEX_FILE = path.join(PERF_DIR, "index.json");
export const DASHBOARD_DIR = path.join(PERF_DIR, "dashboard");
export const DASHBOARD_HTML = path.join(DASHBOARD_DIR, "index.html");

export function ensurePerfDirs() {
  fs.mkdirSync(SNAPSHOTS_DIR, { recursive: true });
  fs.mkdirSync(DASHBOARD_DIR, { recursive: true });
}