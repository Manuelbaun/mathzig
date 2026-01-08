import { describe, expect, it } from "bun:test";
import * as path from "node:path";
import {
  listTranslatedJsonFiles,
  loadTranslatedFile,
  runMathZigCase,
} from "../../../parity/mathjs_examples/runner";
import { MathZig } from "../../../../src/ts/mathzig";

const TRANSLATED_DIR = path.resolve("tests/parity/mathjs_examples/translated");
const translatedFiles = listTranslatedJsonFiles(TRANSLATED_DIR);

describe("mathjs examples — per-file translations", () => {
  it(`found ${translatedFiles.length} translated example files`, () => {
    expect(translatedFiles.length).toBeGreaterThan(0);
  });

  for (const filePath of translatedFiles) {
    const file = loadTranslatedFile(filePath);
    const coreCases = file.cases.filter((c) => c.tier === "core");

    describe(file.source, () => {
      it(`summary: ${file.summary.total} cases (${file.summary.core} core)`, () => {
        expect(file.slug).toBeTruthy();
        expect(file.cases.length).toBe(file.summary.total);
      });

      for (const testCase of coreCases) {
        const title = `line ${testCase.line}: ${testCase.expr}`;
        if (testCase.hazard === "crash") {
          it.skip(`[crash hazard] ${title}`, () => {});
          continue;
        }
        it(title, () => {
          const ctx = MathZig.create();
          try {
            const result = runMathZigCase(ctx, testCase);
            expect(result.status, result.reason ?? "mismatch").toBe("PASS");
          } finally {
            ctx.destroy();
          }
        });
      }
    });
  }
});