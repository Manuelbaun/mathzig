/**
 * Load hybrid feature catalog and derive versioned features.json matrix (§C.3–C.6).
 */
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import { PARITY_ARTIFACTS_DIR, ROOT } from "./paths.ts";
import {
  decideFeatureStatus,
  emptyStatusHistogram,
  type CaseRef,
  type CaseStatus,
  type FeatureStatus,
} from "./feature_status.ts";
import {
  MATRIX_BACKENDS,
  type FeatureCell,
  type FeatureCellBackend,
  type FeaturesDocument,
  type MatrixBackend,
  type StatusHistogram,
} from "./types.ts";

export const DEFAULT_CATALOG_PATH = path.resolve(ROOT, "bench/features/catalog.json");
export const DEFAULT_CASES_DIR = path.resolve(ROOT, "tests/parity/cases");

export type CatalogBackend = {
  id: string;
  kind?: string;
  matrix_column?: boolean;
  aliases?: string[];
  notes?: string;
  inherits_skips_from?: string;
};

export type CatalogCategory = {
  id: string;
  label: string;
};

export type CatalogFeature = {
  id: string;
  category: string;
  label: string;
  description?: string;
  parity_case_files?: string[];
  parity_case_ids?: string[];
  id_prefix?: string | null;
  id_regex?: string | null;
  related_bench_ids?: string[];
  manual?: Partial<Record<string, FeatureStatus | string>>;
  notes?: string;
};

export type FeatureCatalog = {
  schema_version: number;
  backends?: CatalogBackend[];
  categories?: CatalogCategory[];
  features: CatalogFeature[];
  notes?: string;
};

export type BuildFeaturesOptions = {
  versionId: string;
  /** Gate / package task id used in parity CSV filenames: `{taskId}_{backend}.csv`. */
  taskId: string;
  backendsExecuted: readonly string[];
  seq?: number;
  generatedAt?: string;
  catalogPath?: string;
  casesDir?: string;
  parityArtifactsDir?: string;
  /** Pre-loaded catalog (tests). When set, catalogPath is only used for hash if provided. */
  catalog?: FeatureCatalog;
  /** Override catalog file bytes for hash (tests). */
  catalogRaw?: string | Buffer;
};

/** Parse a single CSV line respecting double-quoted fields (exprs contain commas). */
export function splitCsvLine(line: string): string[] {
  const out: string[] = [];
  let cur = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === '"') {
      if (inQuotes && line[i + 1] === '"') {
        cur += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (ch === "," && !inQuotes) {
      out.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  out.push(cur);
  return out;
}

/**
 * Parse parity CSV (`id,expr,status,reason`) → Map of case id → status.
 * Uses a proper quoted-field parser — do not split on bare commas.
 */
export function parseParityCsvById(csvPath: string): Map<string, CaseStatus> {
  const text = fs.readFileSync(csvPath, "utf8");
  const lines = text.split(/\r?\n/).filter(Boolean);
  const map = new Map<string, CaseStatus>();
  if (lines.length < 2) return map;

  const header = splitCsvLine(lines[0]).map((h) => h.trim().toLowerCase());
  let idIdx = header.indexOf("id");
  let statusIdx = header.indexOf("status");
  if (idIdx < 0) idIdx = 0;
  if (statusIdx < 0) statusIdx = 2;

  for (let i = 1; i < lines.length; i += 1) {
    const cols = splitCsvLine(lines[i]);
    const id = (cols[idIdx] ?? "").trim();
    if (!id) continue;
    const raw = (cols[statusIdx] ?? "").trim().toUpperCase();
    if (raw === "PASS") map.set(id, "pass");
    else if (raw === "FAIL") map.set(id, "fail");
    else if (raw === "SKIP") map.set(id, "skip");
  }
  return map;
}

export function catalogHash(content: string | Buffer): string {
  const h = crypto.createHash("sha256").update(content).digest("hex");
  return `sha256:${h}`;
}

export function loadCatalog(catalogPath: string = DEFAULT_CATALOG_PATH): {
  catalog: FeatureCatalog;
  raw: string;
  hash: string;
} {
  const raw = fs.readFileSync(catalogPath, "utf8");
  const catalog = JSON.parse(raw) as FeatureCatalog;
  if (!catalog || !Array.isArray(catalog.features)) {
    throw new Error(`Invalid catalog (missing features[]): ${catalogPath}`);
  }
  if (catalog.schema_version !== 1) {
    throw new Error(`Unsupported catalog schema_version: ${catalog.schema_version}`);
  }
  return { catalog, raw, hash: catalogHash(raw) };
}

/** Load a single parity case file into CaseRef list. */
export function loadCaseFile(filePath: string): CaseRef[] {
  if (!fs.existsSync(filePath)) return [];
  const raw = JSON.parse(fs.readFileSync(filePath, "utf8"));
  if (!Array.isArray(raw)) return [];
  const out: CaseRef[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const id = (item as { id?: unknown }).id;
    if (typeof id !== "string" || !id) continue;
    const skipRaw = (item as { skip?: unknown }).skip;
    const skip = Array.isArray(skipRaw)
      ? skipRaw.filter((s): s is string => typeof s === "string")
      : undefined;
    out.push(skip && skip.length > 0 ? { id, skip } : { id });
  }
  return out;
}

/** Load all case files under casesDir (non-recursive). */
export function loadAllCaseFiles(casesDir: string): Map<string, CaseRef[]> {
  const map = new Map<string, CaseRef[]>();
  if (!fs.existsSync(casesDir)) return map;
  for (const name of fs.readdirSync(casesDir)) {
    if (!name.endsWith(".json")) continue;
    map.set(name, loadCaseFile(path.join(casesDir, name)));
  }
  return map;
}

/**
 * Matcher API (§C.3):
 * case included if:
 *   (file in parity_case_files OR parity_case_files empty and ids-only mode)
 *   AND (parity_case_ids empty OR id in parity_case_ids)
 *   AND (id_prefix null OR id.startsWith(id_prefix))
 *   AND (id_regex null OR new RegExp(id_regex).test(id))
 */
export function matchFeatureCases(
  feature: CatalogFeature,
  casesByFile: Map<string, CaseRef[]>
): CaseRef[] {
  const files = feature.parity_case_files ?? [];
  const ids = feature.parity_case_ids ?? [];
  const idsOnly = files.length === 0 && ids.length > 0;
  const idSet = ids.length > 0 ? new Set(ids) : null;
  const prefix = feature.id_prefix ?? null;
  const regex =
    feature.id_regex != null && feature.id_regex !== ""
      ? new RegExp(feature.id_regex)
      : null;

  let pool: CaseRef[] = [];
  if (idsOnly) {
    // Search all loaded files for explicit ids.
    for (const cases of casesByFile.values()) {
      pool.push(...cases);
    }
  } else {
    for (const file of files) {
      const cases = casesByFile.get(file);
      if (cases) pool.push(...cases);
    }
  }

  // De-dupe by id (first wins — preserves skip from first file).
  const seen = new Set<string>();
  const out: CaseRef[] = [];
  for (const c of pool) {
    if (seen.has(c.id)) continue;
    if (idSet && !idSet.has(c.id)) continue;
    if (prefix != null && !c.id.startsWith(prefix)) continue;
    if (regex && !regex.test(c.id)) continue;
    seen.add(c.id);
    out.push(c);
  }
  return out;
}

function matrixBackendsFromCatalog(catalog: FeatureCatalog): MatrixBackend[] {
  const cols = (catalog.backends ?? [])
    .filter((b) => b.matrix_column === true)
    .map((b) => b.id)
    .filter((id): id is MatrixBackend =>
      (MATRIX_BACKENDS as readonly string[]).includes(id)
    );
  return cols.length > 0 ? cols : [...MATRIX_BACKENDS];
}

function cellFromDecision(
  d: ReturnType<typeof decideFeatureStatus>
): FeatureCellBackend {
  const cell: FeatureCellBackend = {
    status: d.status,
    evidence: d.evidence,
  };
  if (d.evidence === "parity_csv" || d.evidence === "case_skip_all" || d.evidence === "case_skip") {
    cell.pass = d.pass;
    cell.fail = d.fail;
    cell.skip = d.skip;
  } else if (d.pass + d.fail + d.skip > 0) {
    cell.pass = d.pass;
    cell.fail = d.fail;
    cell.skip = d.skip;
  }
  return cell;
}

/**
 * Build the versioned features.json document from catalog + parity evidence.
 *
 * Hard rule: only read CSVs for backends in backendsExecuted.
 */
export function buildFeaturesDocument(opts: BuildFeaturesOptions): FeaturesDocument {
  const catalogPath = opts.catalogPath
    ? path.isAbsolute(opts.catalogPath)
      ? opts.catalogPath
      : path.resolve(ROOT, opts.catalogPath)
    : DEFAULT_CATALOG_PATH;
  const casesDir = opts.casesDir
    ? path.isAbsolute(opts.casesDir)
      ? opts.casesDir
      : path.resolve(ROOT, opts.casesDir)
    : DEFAULT_CASES_DIR;
  const parityArtifactsDir = opts.parityArtifactsDir
    ? path.isAbsolute(opts.parityArtifactsDir)
      ? opts.parityArtifactsDir
      : path.resolve(ROOT, opts.parityArtifactsDir)
    : PARITY_ARTIFACTS_DIR;

  let catalog: FeatureCatalog;
  let hash: string;
  if (opts.catalog) {
    catalog = opts.catalog;
    const raw =
      opts.catalogRaw ??
      (fs.existsSync(catalogPath) ? fs.readFileSync(catalogPath) : JSON.stringify(catalog));
    hash = catalogHash(raw);
  } else {
    const loaded = loadCatalog(catalogPath);
    catalog = loaded.catalog;
    hash = loaded.hash;
  }

  const backends = matrixBackendsFromCatalog(catalog);
  const casesByFile = loadAllCaseFiles(casesDir);
  const executed = [...opts.backendsExecuted];

  // Preload CSV maps only for executed backends.
  const csvMaps = new Map<string, Map<string, CaseStatus>>();
  for (const b of executed) {
    const csvPath = path.join(parityArtifactsDir, `${opts.taskId}_${b}.csv`);
    if (fs.existsSync(csvPath)) {
      csvMaps.set(b, parseParityCsvById(csvPath));
    }
  }

  const cells: FeatureCell[] = [];
  const summary: Record<string, StatusHistogram> = {};
  for (const b of backends) {
    summary[b] = emptyStatusHistogram();
  }

  for (const feature of catalog.features) {
    const matched = matchFeatureCases(feature, casesByFile);
    const by_backend: Record<string, FeatureCellBackend> = {};

    for (const backend of backends) {
      const manual = feature.manual?.[backend] ?? null;
      const isExecuted = executed.includes(backend);
      // NEVER pass CSV for non-executed backends (stale CSV hard rule).
      const csvById = isExecuted ? (csvMaps.get(backend) ?? null) : null;

      const decision = decideFeatureStatus({
        backend,
        backendsExecuted: executed,
        manual,
        cases: matched,
        csvById,
      });

      if (decision.warning) {
        console.warn(
          `build_features: feature=${feature.id} ${decision.warning}`
        );
      }

      by_backend[backend] = cellFromDecision(decision);
      const hist = summary[backend];
      if (hist) {
        const st = decision.status;
        hist[st] = (hist[st] ?? 0) + 1;
      }
    }

    cells.push({
      feature_id: feature.id,
      category: feature.category,
      label: feature.label,
      related_bench_ids: feature.related_bench_ids ?? [],
      by_backend,
    });
  }

  const doc: FeaturesDocument = {
    schema_version: 1,
    version_id: opts.versionId,
    generated_at: opts.generatedAt ?? new Date().toISOString(),
    catalog_hash: hash,
    backends: [...backends],
    backends_executed: executed,
    cells,
    summary,
  };
  if (opts.seq != null) {
    doc.seq = opts.seq;
  }
  return doc;
}

/** CLI: write features.json for inspection / refresh. */
function usage(): never {
  console.error(
    [
      "Usage:",
      "  bun tools/progress/build_features.ts --feature <task_id> [options]",
      "",
      "Options:",
      "  --feature <task_id>           parity CSV task id (required)",
      "  --backends <list>             comma-separated backends_executed (default: zig_vm,ts_ffi)",
      "  --version-id <id>             version_id field (default: task_id)",
      "  --catalog <path>              catalog.json path",
      "  --cases <path>                parity cases dir",
      "  --parity-dir <path>           parity CSV dir",
      "  --out <path>                  write features.json here (default: stdout)",
    ].join("\n")
  );
  process.exit(2);
}

function parseCli(argv: string[]): {
  taskId: string;
  backends: string[];
  versionId?: string;
  catalogPath?: string;
  casesDir?: string;
  parityArtifactsDir?: string;
  out?: string;
} {
  let taskId = "";
  let backends = ["zig_vm", "ts_ffi"];
  let versionId: string | undefined;
  let catalogPath: string | undefined;
  let casesDir: string | undefined;
  let parityArtifactsDir: string | undefined;
  let out: string | undefined;

  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--feature" || a === "--feature-id" || a === "--task-id") {
      taskId = argv[++i] ?? "";
    } else if (a === "--backends") {
      backends = (argv[++i] ?? "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
    } else if (a === "--version-id") {
      versionId = argv[++i];
    } else if (a === "--catalog") {
      catalogPath = argv[++i];
    } else if (a === "--cases") {
      casesDir = argv[++i];
    } else if (a === "--parity-dir") {
      parityArtifactsDir = argv[++i];
    } else if (a === "--out") {
      out = argv[++i];
    } else if (!a.startsWith("-") && !taskId) {
      taskId = a;
    } else {
      usage();
    }
  }
  if (!taskId) usage();
  return { taskId, backends, versionId, catalogPath, casesDir, parityArtifactsDir, out };
}

if (import.meta.main) {
  const args = parseCli(process.argv.slice(2));
  const doc = buildFeaturesDocument({
    versionId: args.versionId ?? args.taskId,
    taskId: args.taskId,
    backendsExecuted: args.backends,
    catalogPath: args.catalogPath,
    casesDir: args.casesDir,
    parityArtifactsDir: args.parityArtifactsDir,
  });
  const text = `${JSON.stringify(doc, null, 2)}\n`;
  if (args.out) {
    const outPath = path.isAbsolute(args.out) ? args.out : path.resolve(ROOT, args.out);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, text, "utf8");
    console.log(`wrote ${outPath}`);
  } else {
    process.stdout.write(text);
  }
}
