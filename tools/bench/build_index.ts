#!/usr/bin/env bun
import * as fs from "node:fs";
import * as path from "node:path";
import type { Snapshot, SnapshotIndex, SnapshotIndexEntry } from "./types";
import { ensurePerfDirs, INDEX_FILE, SNAPSHOTS_DIR } from "./paths";

export function buildIndex(): SnapshotIndex {
  ensurePerfDirs();
  const files = fs.existsSync(SNAPSHOTS_DIR)
    ? fs.readdirSync(SNAPSHOTS_DIR).filter((f) => f.endsWith(".json")).sort()
    : [];

  const entries: SnapshotIndexEntry[] = [];
  for (const file of files) {
    const full = path.join(SNAPSHOTS_DIR, file);
    const snap = JSON.parse(fs.readFileSync(full, "utf8")) as Snapshot;
    entries.push({
      id: snap.snapshot.id,
      kind: snap.snapshot.kind,
      git_tag: snap.snapshot.git_tag,
      git_sha: snap.snapshot.git_sha,
      feature_id: snap.snapshot.feature_id,
      recorded_at: snap.snapshot.recorded_at,
      machine_id: snap.snapshot.machine_id,
      tier: snap.snapshot.tier,
      bench_count: snap.results.length,
      file: `snapshots/${file}`,
    });
  }

  entries.sort((a, b) => a.recorded_at.localeCompare(b.recorded_at));

  const machine_id = entries.length > 0 ? entries[entries.length - 1].machine_id : "unknown";
  const index: SnapshotIndex = {
    generated_at: new Date().toISOString(),
    machine_id,
    snapshots: entries,
  };

  fs.writeFileSync(INDEX_FILE, `${JSON.stringify(index, null, 2)}\n`, "utf8");
  return index;
}

if (import.meta.main) {
  const index = buildIndex();
  console.log(`Wrote index with ${index.snapshots.length} snapshots`);
}