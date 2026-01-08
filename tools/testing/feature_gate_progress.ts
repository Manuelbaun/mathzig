/**
 * Progress package helpers for feature_gate (PR3).
 *
 * Package write is always attempted after the gate finishes unless PROGRESS_DISABLE.
 * Failures are soft by default (never change gate exit status).
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { getProgressPaths } from "../progress/paths.ts";
import type { BenchMode, MetaDocument, ProgressIndex } from "../progress/types.ts";
import { writePackage, type WritePackageResult } from "../progress/write_package.ts";
import { buildProgressIndex } from "../progress/build_progress_index.ts";

/** Truthy env flag: 1 / true / yes / on (case-insensitive). */
export function envFlagEnabled(raw: string | undefined): boolean {
  if (raw === undefined || raw === "") return false;
  const v = raw.trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes" || v === "on";
}

/**
 * Whether the gate should write a progress version package.
 * Disabled when PROGRESS_DISABLE is a truthy flag.
 */
export function shouldWriteProgressPackage(
  env: NodeJS.ProcessEnv | Record<string, string | undefined> = process.env
): boolean {
  return !envFlagEnabled(env.PROGRESS_DISABLE);
}

/**
 * Resolve the latest progress package version_id for a baseline feature, if any.
 * Prefers index.json; falls back to scanning package meta.json files.
 * Returns null when no package exists for the feature (leave baseline_version_id null).
 */
export function resolveLatestBaselineVersionId(
  baselineFeatureId: string,
  progressDir?: string
): string | null {
  if (!baselineFeatureId) return null;

  const { INDEX_FILE, PACKAGES_DIR } = getProgressPaths(progressDir);
  const candidates: Array<{ version_id: string; seq: number }> = [];

  if (fs.existsSync(INDEX_FILE)) {
    try {
      const index = JSON.parse(fs.readFileSync(INDEX_FILE, "utf8")) as ProgressIndex;
      for (const p of index.packages ?? []) {
        if (p.feature_id === baselineFeatureId) {
          candidates.push({ version_id: p.version_id, seq: p.seq ?? 0 });
        }
      }
    } catch {
      // ignore corrupt index; fall through to package scan
    }
  }

  if (candidates.length === 0 && fs.existsSync(PACKAGES_DIR)) {
    for (const name of fs.readdirSync(PACKAGES_DIR)) {
      if (name.startsWith(".")) continue;
      const metaPath = path.join(PACKAGES_DIR, name, "meta.json");
      if (!fs.existsSync(metaPath)) continue;
      try {
        const meta = JSON.parse(fs.readFileSync(metaPath, "utf8")) as MetaDocument;
        if (meta.feature_id === baselineFeatureId && meta.version_id) {
          candidates.push({ version_id: meta.version_id, seq: meta.seq ?? 0 });
        }
      } catch {
        // skip unreadable package
      }
    }
  }

  if (candidates.length === 0) return null;
  candidates.sort((a, b) => {
    if (b.seq !== a.seq) return b.seq - a.seq;
    return b.version_id.localeCompare(a.version_id);
  });
  return candidates[0]!.version_id;
}

export type GateProgressWriteResult = {
  /** PROGRESS_DISABLE (or equivalent) skipped the write. */
  skipped: boolean;
  /** Write succeeded (or was intentionally skipped). */
  ok: boolean;
  /** Human reason for skip; null when not skipped. */
  skipReason: string | null;
  packageDir: string | null;
  versionId: string | null;
  /** Error message when ok=false. */
  errorMessage: string | null;
  durationSec: number;
  /** Resolved baseline package version_id (may be null even with baseline feature). */
  baselineVersionId: string | null;
};

/**
 * Soft write of a progress version package from gate artifacts.
 * Never throws — errors become ok=false with errorMessage.
 */
export function writeGateProgressPackage(opts: {
  featureId: string;
  stepsPath: string;
  baselineFeatureId: string | null;
  benchMode: BenchMode;
  tier: string;
  env?: NodeJS.ProcessEnv | Record<string, string | undefined>;
  progressDir?: string;
}): GateProgressWriteResult {
  const env = opts.env ?? process.env;
  const started = Date.now();
  const duration = () => Math.max(0, Math.round((Date.now() - started) / 1000));

  if (!shouldWriteProgressPackage(env)) {
    return {
      skipped: true,
      ok: true,
      skipReason: "PROGRESS_DISABLE set",
      packageDir: null,
      versionId: null,
      errorMessage: null,
      durationSec: duration(),
      baselineVersionId: null,
    };
  }

  const baselineFeatureId = opts.baselineFeatureId || null;
  let baselineVersionId: string | null = null;
  if (baselineFeatureId) {
    try {
      baselineVersionId = resolveLatestBaselineVersionId(baselineFeatureId, opts.progressDir);
    } catch {
      baselineVersionId = null;
    }
  }

  try {
    const result: WritePackageResult = writePackage({
      featureId: opts.featureId,
      stepsPath: opts.stepsPath,
      baselineFeatureId,
      baselineVersionId,
      benchMode: opts.benchMode,
      tier: opts.tier,
      writeCompare: Boolean(baselineFeatureId),
      rebuildIndex: true,
      progressDir: opts.progressDir,
    });

    return {
      skipped: false,
      ok: true,
      skipReason: null,
      packageDir: result.package_dir,
      versionId: result.version_id,
      errorMessage: null,
      durationSec: duration(),
      baselineVersionId,
    };
  } catch (err) {
    return {
      skipped: false,
      ok: false,
      skipReason: null,
      packageDir: null,
      versionId: null,
      errorMessage: err instanceof Error ? err.message : String(err),
      durationSec: duration(),
      baselineVersionId,
    };
  }
}

/**
 * Optional stub for PROGRESS_REFRESH_APP.
 * Until apps/progress exists, only rebuilds the progress index.
 * Soft: never throws.
 */
export function maybeRefreshProgressApp(
  env: NodeJS.ProcessEnv | Record<string, string | undefined> = process.env,
  progressDir?: string
): { ran: boolean; ok: boolean; message: string } {
  if (!envFlagEnabled(env.PROGRESS_REFRESH_APP)) {
    return { ran: false, ok: true, message: "PROGRESS_REFRESH_APP not set" };
  }
  try {
    const index = buildProgressIndex(progressDir);
    return {
      ran: true,
      ok: true,
      message: `rebuilt progress index (${index.packages.length} packages); apps/progress data export not available yet`,
    };
  } catch (err) {
    return {
      ran: true,
      ok: false,
      message: err instanceof Error ? err.message : String(err),
    };
  }
}
