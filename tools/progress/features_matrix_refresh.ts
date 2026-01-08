#!/usr/bin/env bun
/**
 * Rebuild features.json for a progress package (or emit a standalone matrix).
 *
 * Does not re-run parity by default — reuses CSVs under tests/artifacts/parity/
 * (or --parity-dir). Optional --run-parity invokes tests/parity/cli.ts.
 *
 * Usage:
 *   bun tools/progress/features_matrix_refresh.ts --feature <id> [--backends list]
 *   bun tools/progress/features_matrix_refresh.ts --feature <id> --package <version_id>
 *   bun tools/progress/features_matrix_refresh.ts --feature <id> --out path/to/features.json
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { buildFeaturesDocument } from "./build_features.ts";
import { getProgressPaths, PARITY_ARTIFACTS_DIR, ROOT } from "./paths.ts";
import { MATRIX_BACKENDS } from "./types.ts";
import { writeJsonAtomic } from "../testing/feature_gate_steps.ts";

/** Default when not rewriting a package and --backends omitted. */
const DEFAULT_STANDALONE_BACKENDS = [...MATRIX_BACKENDS] as string[];

function usage(): never {
  console.error(
    [
      "Usage:",
      "  bun tools/progress/features_matrix_refresh.ts --feature <task_id> [options]",
      "",
      "Options:",
      "  --feature <task_id>           parity CSV / gate feature id (required)",
      "  --backends <list>             backends_executed (standalone default: all matrix columns;",
      "                                with --package: default from meta.parity_backends_executed)",
      "  --package <version_id>        rewrite features.json inside an existing package",
      "  --progress-dir <path>         progress root (default: tests/artifacts/progress)",
      "  --catalog <path>              catalog.json",
      "  --cases <path>                parity cases dir",
      "  --parity-dir <path>           parity CSV dir",
      "  --out <path>                  write features.json (when not using --package)",
      "  --run-parity                  run bun tests/parity/cli.ts --full --backends=… first",
    ].join("\n")
  );
  process.exit(2);
}

export type RefreshArgs = {
  featureId: string;
  /** Explicit --backends list, or null if omitted. */
  backends: string[] | null;
  packageId?: string;
  progressDir?: string;
  catalogPath?: string;
  casesDir?: string;
  parityArtifactsDir?: string;
  out?: string;
  runParity: boolean;
};

export function parseRefreshArgs(argv: string[]): RefreshArgs {
  let featureId = "";
  let backends: string[] | null = null;
  let packageId: string | undefined;
  let progressDir: string | undefined;
  let catalogPath: string | undefined;
  let casesDir: string | undefined;
  let parityArtifactsDir: string | undefined;
  let out: string | undefined;
  let runParity = false;

  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--feature") {
      featureId = argv[++i] ?? "";
    } else if (a === "--backends") {
      backends = (argv[++i] ?? "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
    } else if (a === "--package") {
      packageId = argv[++i];
    } else if (a === "--progress-dir") {
      progressDir = argv[++i];
    } else if (a === "--catalog") {
      catalogPath = argv[++i];
    } else if (a === "--cases") {
      casesDir = argv[++i];
    } else if (a === "--parity-dir") {
      parityArtifactsDir = argv[++i];
    } else if (a === "--out") {
      out = argv[++i];
    } else if (a === "--run-parity") {
      runParity = true;
    } else if (!a.startsWith("-") && !featureId) {
      featureId = a;
    } else {
      usage();
    }
  }
  if (!featureId) usage();
  return {
    featureId,
    backends,
    packageId,
    progressDir,
    catalogPath,
    casesDir,
    parityArtifactsDir,
    out,
    runParity,
  };
}

/**
 * Parity CLI only accepts equals-form flags (`--task-id=…`, `--backends=…`).
 * Space-separated form is rejected as unknown args (see tests/parity/cli.ts).
 */
export function buildParityCliArgs(featureId: string, backends: string[]): string[] {
  return [
    "bun",
    "tests/parity/cli.ts",
    "--full",
    `--task-id=${featureId}`,
    `--backends=${backends.join(",")}`,
  ];
}

export function runParityCli(featureId: string, backends: string[]): void {
  const cmd = buildParityCliArgs(featureId, backends);
  console.log(`features_matrix_refresh: running ${cmd.join(" ")}`);
  const proc = Bun.spawnSync({
    cmd,
    cwd: ROOT,
    stdout: "inherit",
    stderr: "inherit",
  });
  if (proc.exitCode !== 0) {
    throw new Error(`parity CLI failed with exit ${proc.exitCode}`);
  }
}

/**
 * Resolve backends_executed for a matrix rebuild.
 * - Explicit --backends always wins.
 * - With --package and no --backends: use meta.parity_backends_executed,
 *   then correctness.parity.backends_executed, then features.backends_executed.
 * - Standalone (no package): default all matrix columns.
 */
export function resolveBackendsExecuted(opts: {
  explicitBackends: string[] | null;
  packageDir: string | null;
}): string[] {
  if (opts.explicitBackends != null && opts.explicitBackends.length > 0) {
    return [...opts.explicitBackends];
  }
  if (opts.packageDir) {
    const fromPkg = readPackageBackendsExecuted(opts.packageDir);
    if (fromPkg && fromPkg.length > 0) return fromPkg;
    // Package present but no executed list recorded — fail closed (empty)
    // rather than claiming all matrix backends ran.
    console.warn(
      "features_matrix_refresh: --package has no parity_backends_executed in meta/correctness/features; using empty backends_executed"
    );
    return [];
  }
  return [...DEFAULT_STANDALONE_BACKENDS];
}

export function readPackageBackendsExecuted(packageDir: string): string[] | null {
  const tryRead = (file: string, pick: (raw: unknown) => string[] | null): string[] | null => {
    const p = path.join(packageDir, file);
    if (!fs.existsSync(p)) return null;
    try {
      const raw = JSON.parse(fs.readFileSync(p, "utf8"));
      return pick(raw);
    } catch {
      return null;
    }
  };

  const fromMeta = tryRead("meta.json", (raw) => {
    const m = raw as { parity_backends_executed?: unknown };
    if (Array.isArray(m.parity_backends_executed)) {
      return m.parity_backends_executed.filter((b): b is string => typeof b === "string");
    }
    return null;
  });
  if (fromMeta && fromMeta.length > 0) return fromMeta;

  const fromCorrectness = tryRead("correctness.json", (raw) => {
    const c = raw as { parity?: { backends_executed?: unknown } };
    if (Array.isArray(c.parity?.backends_executed)) {
      return c.parity!.backends_executed!.filter((b): b is string => typeof b === "string");
    }
    return null;
  });
  if (fromCorrectness && fromCorrectness.length > 0) return fromCorrectness;

  const fromFeatures = tryRead("features.json", (raw) => {
    const f = raw as { backends_executed?: unknown };
    if (Array.isArray(f.backends_executed)) {
      return f.backends_executed.filter((b): b is string => typeof b === "string");
    }
    return null;
  });
  if (fromFeatures && fromFeatures.length > 0) return fromFeatures;

  return null;
}

export function refreshFeatures(args: RefreshArgs): {
  doc: ReturnType<typeof buildFeaturesDocument>;
  packageDir: string | null;
  backendsExecuted: string[];
} {
  const parityDir = args.parityArtifactsDir
    ? path.isAbsolute(args.parityArtifactsDir)
      ? args.parityArtifactsDir
      : path.resolve(ROOT, args.parityArtifactsDir)
    : PARITY_ARTIFACTS_DIR;

  let versionId = args.featureId;
  let packageDir: string | null = null;
  let seq: number | undefined;

  if (args.packageId) {
    const { PACKAGES_DIR } = getProgressPaths(args.progressDir);
    packageDir = path.join(PACKAGES_DIR, args.packageId);
    if (!fs.existsSync(packageDir)) {
      throw new Error(`package not found: ${packageDir}`);
    }
    versionId = args.packageId;
    const metaPath = path.join(packageDir, "meta.json");
    if (fs.existsSync(metaPath)) {
      try {
        const meta = JSON.parse(fs.readFileSync(metaPath, "utf8")) as {
          seq?: number;
          version_id?: string;
        };
        if (typeof meta.seq === "number") seq = meta.seq;
        if (meta.version_id) versionId = meta.version_id;
      } catch {
        /* ignore */
      }
    }
  }

  const backendsExecuted = resolveBackendsExecuted({
    explicitBackends: args.backends,
    packageDir,
  });

  if (args.runParity) {
    if (backendsExecuted.length === 0) {
      throw new Error(
        "features_matrix_refresh: --run-parity requires a non-empty backends list (--backends or package meta)"
      );
    }
    runParityCli(args.featureId, backendsExecuted);
  }

  const doc = buildFeaturesDocument({
    versionId,
    taskId: args.featureId,
    backendsExecuted,
    seq,
    catalogPath: args.catalogPath,
    casesDir: args.casesDir,
    parityArtifactsDir: parityDir,
  });

  return { doc, packageDir, backendsExecuted };
}

function main() {
  const args = parseRefreshArgs(process.argv.slice(2));
  const { doc, packageDir } = refreshFeatures(args);

  if (packageDir) {
    const outPath = path.join(packageDir, "features.json");
    writeJsonAtomic(outPath, doc);
    console.log(
      JSON.stringify(
        {
          package: args.packageId,
          features: path.relative(ROOT, outPath),
          catalog_hash: doc.catalog_hash,
          cells: doc.cells.length,
          backends_executed: doc.backends_executed,
        },
        null,
        2
      )
    );
    return;
  }

  if (args.out) {
    const outPath = path.isAbsolute(args.out) ? args.out : path.resolve(ROOT, args.out);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    writeJsonAtomic(outPath, doc);
    console.log(
      JSON.stringify(
        {
          out: path.relative(ROOT, outPath),
          catalog_hash: doc.catalog_hash,
          cells: doc.cells.length,
          backends_executed: doc.backends_executed,
        },
        null,
        2
      )
    );
    return;
  }

  process.stdout.write(`${JSON.stringify(doc, null, 2)}\n`);
}

if (import.meta.main) {
  try {
    main();
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  }
}
