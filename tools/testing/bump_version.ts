import * as fs from "node:fs";
import * as path from "node:path";

type BumpKind = "major" | "minor" | "patch";
type SemVer = { major: number; minor: number; patch: number };

const root = process.cwd();
const versionFile = path.resolve(root, "src", "VERSION");
const arg = process.argv[2];

if (!arg) {
  console.error("Usage: bun tools/testing/bump_version.ts <major|minor|patch|x.y.z>");
  process.exit(2);
}

const currentRaw = fs.readFileSync(versionFile, "utf8").trim();
const current = parseSemVer(currentRaw);
const next = isBumpKind(arg) ? bump(current, arg) : parseSemVer(arg);

fs.writeFileSync(versionFile, `${formatSemVer(next)}\n`, "utf8");
console.log(`VERSION: ${formatSemVer(current)} -> ${formatSemVer(next)}`);

function isBumpKind(v: string): v is BumpKind {
  return v === "major" || v === "minor" || v === "patch";
}

function bump(v: SemVer, kind: BumpKind): SemVer {
  if (kind === "major") return { major: v.major + 1, minor: 0, patch: 0 };
  if (kind === "minor") return { major: v.major, minor: v.minor + 1, patch: 0 };
  return { major: v.major, minor: v.minor, patch: v.patch + 1 };
}

function parseSemVer(s: string): SemVer {
  const m = s.match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!m) {
    throw new Error(`Invalid semver '${s}'. Expected MAJOR.MINOR.PATCH`);
  }
  return {
    major: Number(m[1]),
    minor: Number(m[2]),
    patch: Number(m[3]),
  };
}

function formatSemVer(v: SemVer): string {
  return `${v.major}.${v.minor}.${v.patch}`;
}
