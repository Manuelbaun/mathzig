#!/usr/bin/env bun
/**
 * Scan progress packages → index.json sorted by seq ascending.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { writeJsonAtomic } from "../testing/feature_gate_steps.ts";
import { ensureProgressDirs, getProgressPaths, ROOT } from "./paths.ts";
import type { MetaDocument, ProgressIndex, ProgressIndexEntry } from "./types.ts";

export function buildProgressIndex(progressDir?: string): ProgressIndex {
  const { PROGRESS_DIR, PACKAGES_DIR, INDEX_FILE } = ensureProgressDirs(progressDir);
  const entries: ProgressIndexEntry[] = [];

  if (fs.existsSync(PACKAGES_DIR)) {
    for (const name of fs.readdirSync(PACKAGES_DIR)) {
      // Skip hidden / atomic-publish staging dirs (e.g. `.tmp-…`).
      if (name.startsWith(".")) continue;
      const metaPath = path.join(PACKAGES_DIR, name, "meta.json");
      if (!fs.existsSync(metaPath)) continue;
      try {
        const meta = JSON.parse(fs.readFileSync(metaPath, "utf8")) as MetaDocument;
        if (!meta.version_id) continue;
        // Directory name must match package identity (reject phantom/staging dirs).
        if (name !== meta.version_id) {
          console.warn(
            `build_progress_index: skip ${name}: directory name !== meta.version_id (${meta.version_id})`
          );
          continue;
        }
        entries.push({
          version_id: meta.version_id,
          seq: meta.seq ?? 0,
          sort_key: meta.sort_key ?? meta.version_id,
          label: meta.label ?? meta.feature_id,
          kind: meta.kind,
          status: meta.status,
          feature_id: meta.feature_id,
          git_sha: meta.git_sha,
          git_tag: meta.git_tag,
          recorded_at: meta.recorded_at,
          machine_id: meta.machine_id,
          has_performance: meta.has_performance,
          tier: meta.tier,
          bench_mode: meta.bench_mode,
          path: `packages/${meta.version_id}`,
          source: "local",
        });
      } catch (err) {
        console.warn(`build_progress_index: skip ${name}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
  }

  entries.sort((a, b) => {
    if (a.seq !== b.seq) return a.seq - b.seq;
    return a.sort_key.localeCompare(b.sort_key);
  });

  const index: ProgressIndex = {
    schema_version: 1,
    generated_at: new Date().toISOString(),
    packages: entries,
  };

  writeJsonAtomic(INDEX_FILE, index);
  return index;
}

if (import.meta.main) {
  const override = process.argv[2]; // optional progress dir
  const index = buildProgressIndex(override);
  const { INDEX_FILE } = getProgressPaths(override);
  console.log(
    `Wrote ${path.relative(ROOT, INDEX_FILE)} with ${index.packages.length} packages (sorted by seq)`
  );
}
