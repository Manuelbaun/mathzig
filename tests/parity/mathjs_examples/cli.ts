#!/usr/bin/env bun
/**
 * MathJS examples parity runner.
 *
 * Reads static translations from tests/parity/mathjs_examples/translated/*.json
 *
 * Usage:
 *   bun tests/parity/mathjs_examples/cli.ts --core
 *   bun tests/parity/mathjs_examples/cli.ts --extended
 *   bun tests/parity/mathjs_examples/cli.ts --all
 */

import { runAllTranslated, writeArtifacts } from "./runner";

const args = process.argv.slice(2);

const tier = args.includes("--extended")
  ? "extended"
  : args.includes("--all")
    ? "all"
    : "core";

const summary = runAllTranslated({ tier, isolated: true });
const { defectPath, defects } = writeArtifacts(summary);

console.log(`MathJS examples parity (${tier})`);
console.log(`  total=${summary.total} pass=${summary.pass} fail=${summary.fail} skip=${summary.skip} error=${summary.error}`);
console.log(`  defects: ${defectPath} (${defects.length})`);

if (defects.length > 0) {
  console.log("\nFailures:");
  for (const d of defects.slice(0, 40)) {
    console.log(`  [${d.status}] ${d.source}:${d.line}  ${d.expr}`);
    if (d.reason) console.log(`         ${d.reason}`);
  }
  if (defects.length > 40) console.log(`  ... and ${defects.length - 40} more`);
}

process.exit(summary.fail + summary.error > 0 ? 1 : 0);