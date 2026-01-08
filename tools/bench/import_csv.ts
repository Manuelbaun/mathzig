#!/usr/bin/env bun
import * as fs from "node:fs";
import * as path from "node:path";
import { parseCsvText } from "./parse";
import { rowsToSnapshot } from "./snapshot";
import { ensurePerfDirs, PERF_LOG, SNAPSHOTS_DIR } from "./paths";
import { buildIndex } from "./build_index";

function main() {
  ensurePerfDirs();
  if (!fs.existsSync(PERF_LOG)) {
    console.error(`Missing ${PERF_LOG}`);
    process.exit(2);
  }

  const rows = parseCsvText(fs.readFileSync(PERF_LOG, "utf8"));
  const featureIds = [...new Set(rows.map((r) => r.featureId))].sort();

  let written = 0;
  for (const featureId of featureIds) {
    const snapshot = rowsToSnapshot(rows, { featureId, tier: "imported" });
    if (!snapshot) continue;
    const out = pathForSnapshot(snapshot.snapshot.id);
    fs.writeFileSync(out, `${JSON.stringify(snapshot, null, 2)}\n`, "utf8");
    written += 1;
  }

  buildIndex();
  console.log(`Imported ${written} snapshots from CSV into ${SNAPSHOTS_DIR}`);
}

function pathForSnapshot(id: string) {
  const safe = id.replace(/[^a-zA-Z0-9._-]+/g, "_");
  return `${SNAPSHOTS_DIR}/${safe}.json`;
}

main();