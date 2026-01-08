import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { buildStatusMarkdown, writeStatusReport } from "../../tools/status_report.ts";

const ROOT = path.resolve(import.meta.dir, "../..");
const STATUS = path.join(ROOT, "docs/STATUS.md");

describe("status_report (task-20)", () => {
  test("regeneration is byte-identical (same-revision idempotence)", () => {
    const a = buildStatusMarkdown();
    const b = buildStatusMarkdown();
    expect(a).toBe(b);
    expect(a).toContain("# MathZig status report");
    expect(a).toContain("## Stamp");
    expect(a).toContain("## Strict bun gate");
    expect(a).toContain("## Quarantine list");
    expect(a).toContain("## Expression parity catalog");
    expect(a).toContain("## Graph corpus × runner matrix");
    expect(a).toContain("tests/parity/cases/");
  });

  test("write then --check path matches (if STATUS already present, overwrite and re-read)", () => {
    const md = writeStatusReport(STATUS);
    const onDisk = fs.readFileSync(STATUS, "utf8");
    expect(onDisk).toBe(md);
    // Second write must not change
    const md2 = writeStatusReport(STATUS);
    expect(md2).toBe(onDisk);
  });

  test("no machine-local file:/// URL links under docs/plans or specs", () => {
    // Flag real markdown/HTML links to machine-local file:/// URLs.
    // Prose that mentions the ban (AUDIT / task-20) may contain the string
    // "file:///Users/..." as an example without being a navigable link.
    const linkRe = /\]\(file:\/\/\/[^)]+\)|href=["']file:\/\/\/[^"']+["']/g;
    const roots = [
      path.join(ROOT, "docs/plans"),
      path.join(ROOT, "specs"),
    ];
    const offenders: string[] = [];
    const walk = (dir: string) => {
      if (!fs.existsSync(dir)) return;
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, ent.name);
        if (ent.isDirectory()) walk(p);
        else if (ent.name.endsWith(".md") || ent.name.endsWith(".json")) {
          const text = fs.readFileSync(p, "utf8");
          if (linkRe.test(text)) {
            offenders.push(path.relative(ROOT, p));
          }
          linkRe.lastIndex = 0;
        }
      }
    };
    for (const r of roots) walk(r);
    expect(offenders).toEqual([]);
  });
});
