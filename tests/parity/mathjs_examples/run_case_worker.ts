#!/usr/bin/env bun
/**
 * Isolated worker for a single case from a translated example file.
 */
import { loadTranslatedFile, findCaseInFile, runMathZigCase } from "./runner";
import { MathZig } from "../../../src/ts/mathzig";

const filePath = process.argv[2];
const caseId = process.argv[3];
if (!filePath || !caseId) {
  console.error("usage: run_case_worker.ts <translated.json> <case-id>");
  process.exit(2);
}

const file = loadTranslatedFile(filePath);
const testCase = findCaseInFile(file, caseId);
if (!testCase) {
  console.error(`unknown case ${caseId} in ${filePath}`);
  process.exit(2);
}

const ctx = MathZig.create();
try {
  const result = runMathZigCase(ctx, testCase);
  process.stdout.write(JSON.stringify(result));
} finally {
  ctx.destroy();
}