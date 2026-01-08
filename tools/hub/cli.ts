#!/usr/bin/env bun
/**
 * MathZig Developer Hub — single place to list, inspect, and run commands.
 *
 * Usage:
 *   bun run hub                 # interactive menu
 *   bun run hub list            # all commands
 *   bun run hub list test       # filter by category
 *   bun run hub show feature-gate
 *   bun run hub run feature-gate -- my_feature
 *   bun run hub where           # data locations
 *   bun run hub env             # env vars
 *   bun run hub docs            # write docs/COMMANDS.md
 *   bun run hub protocol        # Agents.md gate order
 *   bun run hub workflow e2e-progress -- <feature_id>
 */
import * as fs from "node:fs";
import * as path from "node:path";
import * as readline from "node:readline";

const ROOT = process.cwd();
const CATALOG_PATH = path.resolve(ROOT, "tools/hub/catalog.json");
const DOCS_PATH = path.resolve(ROOT, "docs/COMMANDS.md");

type ArgDef = {
  name: string;
  required?: boolean;
  optional?: boolean;
  default?: string;
  hint?: string;
  flag?: boolean;
};

type Command = {
  id: string;
  category: string;
  title: string;
  summary?: string;
  cmd?: string[];
  npm?: string;
  args?: ArgDef[];
  env?: string[];
  artifacts?: string[];
  protocol_order?: number;
  primary?: boolean;
  workflow?: boolean;
  steps?: string[];
};

type Catalog = {
  schema_version: number;
  title: string;
  description: string;
  data_locations: Array<{ id: string; path: string; description: string }>;
  env_globals: Array<{ name: string; default: string; description: string }>;
  commands: Command[];
  categories: Array<{ id: string; label: string; order: number }>;
};

function loadCatalog(): Catalog {
  if (!fs.existsSync(CATALOG_PATH)) {
    console.error(`Missing catalog: ${CATALOG_PATH}`);
    process.exit(1);
  }
  return JSON.parse(fs.readFileSync(CATALOG_PATH, "utf8")) as Catalog;
}

function byCategory(cat: Catalog): Map<string, Command[]> {
  const map = new Map<string, Command[]>();
  for (const c of cat.commands) {
    const list = map.get(c.category) ?? [];
    list.push(c);
    map.set(c.category, list);
  }
  return map;
}

function categoryLabel(cat: Catalog, id: string): string {
  return cat.categories.find((c) => c.id === id)?.label ?? id;
}

function sortedCategories(cat: Catalog): Array<{ id: string; label: string }> {
  return [...cat.categories].sort((a, b) => a.order - b.order);
}

function findCommand(cat: Catalog, id: string): Command | undefined {
  return cat.commands.find((c) => c.id === id || c.npm === id);
}

function printHeader(cat: Catalog) {
  console.log(`\n${cat.title}`);
  console.log(cat.description);
  console.log(`Catalog: tools/hub/catalog.json\n`);
}

function listCommands(cat: Catalog, categoryFilter?: string) {
  printHeader(cat);
  const groups = byCategory(cat);
  for (const { id, label } of sortedCategories(cat)) {
    if (categoryFilter && id !== categoryFilter && label.toLowerCase() !== categoryFilter.toLowerCase()) {
      continue;
    }
    const cmds = groups.get(id);
    if (!cmds?.length) continue;
    console.log(`## ${label} (${id})`);
    for (const c of cmds) {
      const primary = c.primary ? " ★" : "";
      console.log(`  ${c.id.padEnd(22)} ${c.title}${primary}`);
      if (c.summary) console.log(`    ${c.summary}`);
      if (c.cmd) console.log(`    $ ${c.cmd.join(" ")}${c.npm ? `  [bun run ${c.npm}]` : ""}`);
      else if (c.npm) console.log(`    [bun run ${c.npm}]`);
    }
    console.log("");
  }
  console.log("Tip: bun run hub show <id>   |   bun run hub run <id> -- [args…]");
  console.log("     bun run hub where       |   bun run hub env");
}

function showCommand(cat: Catalog, id: string) {
  const c = findCommand(cat, id);
  if (!c) {
    console.error(`Unknown command: ${id}`);
    console.error(`Try: bun run hub list`);
    process.exit(1);
  }
  console.log(`\n# ${c.title}`);
  console.log(`id: ${c.id}`);
  console.log(`category: ${c.category} (${categoryLabel(cat, c.category)})`);
  if (c.summary) console.log(`\n${c.summary}`);
  if (c.cmd) console.log(`\nCommand:\n  ${c.cmd.join(" ")}`);
  if (c.npm) console.log(`\npackage.json script:\n  bun run ${c.npm}`);
  if (c.workflow && c.steps) {
    console.log(`\nWorkflow steps: ${c.steps.join(" → ")}`);
  }
  if (c.args?.length) {
    console.log(`\nArguments:`);
    for (const a of c.args) {
      const req = a.required ? "required" : "optional";
      const def = a.default != null ? ` default=${a.default}` : "";
      const hint = a.hint ? ` — ${a.hint}` : "";
      const flag = a.flag ? " (flag)" : "";
      console.log(`  ${a.name.padEnd(24)} ${req}${def}${flag}${hint}`);
    }
  }
  if (c.env?.length) {
    console.log(`\nRelevant env:`);
    for (const name of c.env) {
      const g = cat.env_globals.find((e) => e.name === name);
      if (g) console.log(`  ${g.name}=${g.default}  # ${g.description}`);
      else console.log(`  ${name}`);
    }
  }
  if (c.artifacts?.length) {
    console.log(`\nArtifacts written:`);
    for (const a of c.artifacts) console.log(`  ${a}`);
  }
  console.log(`\nRun:\n  bun run hub run ${c.id} -- <args…>\n`);
}

function showWhere(cat: Catalog) {
  console.log("\n# Data locations\n");
  for (const d of cat.data_locations) {
    console.log(`${d.path}`);
    console.log(`  ${d.description}\n`);
  }
}

function showEnv(cat: Catalog) {
  console.log("\n# Environment variables\n");
  for (const e of cat.env_globals) {
    console.log(`${e.name}`);
    console.log(`  default: ${e.default}`);
    console.log(`  ${e.description}\n`);
  }
}

function showProtocol(cat: Catalog) {
  console.log("\n# Agents.md / feature protocol order\n");
  console.log("1. Add/update parity JSON vectors in tests/parity/cases/");
  console.log("2. zig build vm-baseline");
  console.log("3. zig build test");
  console.log("4. bun test");
  console.log("5. parity --quick / --full");
  console.log("6. ONLY THEN perf + progress package (feature-gate does 2–6)\n");
  const ordered = cat.commands
    .filter((c) => c.protocol_order != null)
    .sort((a, b) => (a.protocol_order ?? 0) - (b.protocol_order ?? 0));
  for (const c of ordered) {
    console.log(`  [${c.protocol_order}] ${c.id} — ${c.title}`);
  }
  console.log("\nPrimary entry: bun run hub run feature-gate -- <feature_id>\n");
}

function runCommand(cat: Catalog, id: string, extraArgs: string[]): number {
  const c = findCommand(cat, id);
  if (!c) {
    console.error(`Unknown command: ${id}`);
    process.exit(1);
  }
  if (c.workflow && c.steps?.length) {
    return runWorkflow(cat, c, extraArgs);
  }
  if (!c.cmd?.length) {
    console.error(`Command ${id} has no cmd to run`);
    process.exit(1);
  }
  const argv = [...c.cmd, ...extraArgs];
  console.log(`\n→ ${argv.join(" ")}\n`);
  const res = Bun.spawnSync({
    cmd: argv,
    cwd: ROOT,
    env: process.env,
    stdout: "inherit",
    stderr: "inherit",
    stdin: "inherit",
  });
  return res.exitCode ?? 1;
}

function runWorkflow(cat: Catalog, workflow: Command, extraArgs: string[]): number {
  const steps = workflow.steps ?? [];
  console.log(`\nWorkflow: ${workflow.title}`);
  console.log(`Steps: ${steps.join(" → ")}\n`);

  // e2e-progress: first arg is feature_id for feature-gate; then app-data needs no args
  for (const stepId of steps) {
    const step = findCommand(cat, stepId);
    if (!step) {
      console.error(`Workflow step missing: ${stepId}`);
      return 1;
    }
    let stepArgs: string[] = [];
    if (stepId === "feature-gate") {
      if (extraArgs.length === 0) {
        console.error("e2e-progress requires feature_id: bun run hub workflow e2e-progress -- <feature_id> [baseline]");
        return 2;
      }
      stepArgs = extraArgs;
      // ensure progress index refresh for app
      process.env.PROGRESS_REFRESH_APP = process.env.PROGRESS_REFRESH_APP ?? "1";
    }
    console.log(`\n======== ${step.title} (${step.id}) ========`);
    const code = runCommand(cat, stepId, stepArgs);
    if (code !== 0) {
      console.error(`\nWorkflow stopped: ${stepId} exited ${code}`);
      return code;
    }
  }
  console.log(`\nWorkflow complete: ${workflow.id}`);
  console.log(`Next: bun run hub run progress-dev`);
  return 0;
}

function renderDocs(cat: Catalog): string {
  const lines: string[] = [];
  lines.push(`# ${cat.title}`);
  lines.push("");
  lines.push("> **Single source of truth.** Do not hunt through package.json / tools/*/README.");
  lines.push("> Update `tools/hub/catalog.json`, then run `bun run hub docs` to regenerate this file.");
  lines.push("");
  lines.push(cat.description);
  lines.push("");
  lines.push("## Quick start");
  lines.push("");
  lines.push("```bash");
  lines.push("bun run hub                 # interactive menu");
  lines.push("bun run hub list            # all commands");
  lines.push("bun run hub show feature-gate");
  lines.push("bun run hub run feature-gate -- my_feature");
  lines.push("bun run hub workflow e2e-progress -- my_feature");
  lines.push("bun run hub where           # where data lives");
  lines.push("bun run hub env             # env vars");
  lines.push("bun run hub protocol        # test order");
  lines.push("```");
  lines.push("");
  lines.push("## Recommended daily path");
  lines.push("");
  lines.push("```bash");
  lines.push("bun run hub run feature-gate -- <feature_id> [baseline_id]");
  lines.push("bun run hub run progress-app-data");
  lines.push("bun run hub run progress-dev");
  lines.push("```");
  lines.push("");
  lines.push("Or: `bun run hub workflow e2e-progress -- <feature_id>`");
  lines.push("");
  lines.push("## Data locations");
  lines.push("");
  lines.push("| Path | Description |");
  lines.push("|------|-------------|");
  for (const d of cat.data_locations) {
    lines.push(`| \`${d.path}\` | ${d.description} |`);
  }
  lines.push("");
  lines.push("## Environment variables");
  lines.push("");
  lines.push("| Name | Default | Description |");
  lines.push("|------|---------|-------------|");
  for (const e of cat.env_globals) {
    lines.push(`| \`${e.name}\` | \`${e.default}\` | ${e.description} |`);
  }
  lines.push("");
  lines.push("## Protocol (Agents.md)");
  lines.push("");
  lines.push("1. Parity JSON vectors  ");
  lines.push("2. `zig build vm-baseline`  ");
  lines.push("3. `zig build test`  ");
  lines.push("4. `bun test`  ");
  lines.push("5. Parity quick/full  ");
  lines.push("6. Perf / feature-gate / progress package  ");
  lines.push("");
  lines.push("## Commands by category");
  lines.push("");
  const groups = byCategory(cat);
  for (const { id, label } of sortedCategories(cat)) {
    const cmds = groups.get(id);
    if (!cmds?.length) continue;
    lines.push(`### ${label}`);
    lines.push("");
    for (const c of cmds) {
      lines.push(`#### \`${c.id}\`${c.primary ? " ★ primary" : ""}`);
      lines.push("");
      lines.push(c.summary ?? c.title);
      lines.push("");
      if (c.cmd) lines.push(`\`\`\`bash\n${c.cmd.join(" ")}\n\`\`\``);
      if (c.npm) lines.push(`npm script: \`bun run ${c.npm}\``);
      if (c.args?.length) {
        lines.push("");
        lines.push("Args:");
        for (const a of c.args) {
          const req = a.required ? "required" : "optional";
          lines.push(`- \`${a.name}\` (${req}${a.default != null ? `, default \`${a.default}\`` : ""})${a.hint ? `: ${a.hint}` : ""}`);
        }
      }
      if (c.artifacts?.length) {
        lines.push("");
        lines.push("Artifacts: " + c.artifacts.map((a) => `\`${a}\``).join(", "));
      }
      lines.push("");
    }
  }
  lines.push("---");
  lines.push("");
  lines.push(`Generated from \`tools/hub/catalog.json\` (schema v${cat.schema_version}).`);
  lines.push("");
  return lines.join("\n");
}

function writeDocs(cat: Catalog) {
  const md = renderDocs(cat);
  fs.mkdirSync(path.dirname(DOCS_PATH), { recursive: true });
  fs.writeFileSync(DOCS_PATH, md, "utf8");
  console.log(`Wrote ${path.relative(ROOT, DOCS_PATH)}`);
}

async function interactive(cat: Catalog) {
  printHeader(cat);
  console.log("What do you want to do?");
  console.log("  1) List all commands");
  console.log("  2) Show protocol (test order)");
  console.log("  3) Where is data?");
  console.log("  4) Env vars");
  console.log("  5) Browse by category → run");
  console.log("  6) Run correctness (recommended)");
  console.log("  7) Measure perf (needs feature_id)");
  console.log("  8) Write docs/COMMANDS.md");
  console.log("  0) Exit");

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const ask = (q: string) =>
    new Promise<string>((resolve) => {
      rl.question(q, (ans) => resolve(ans.trim()));
    });

  const choice = await ask("\nChoice [1]: ");
  const n = choice === "" ? "1" : choice;

  try {
    if (n === "0") return 0;
    if (n === "1") {
      listCommands(cat);
      return 0;
    }
    if (n === "2") {
      showProtocol(cat);
      return 0;
    }
    if (n === "3") {
      showWhere(cat);
      return 0;
    }
    if (n === "4") {
      showEnv(cat);
      return 0;
    }
    if (n === "8") {
      writeDocs(cat);
      return 0;
    }
    if (n === "6") {
      const stage = await ask("stage [all|zig|backends|boundary|ts_ffi|…] (empty=all): ");
      const args = stage ? [stage] : [];
      return runCommand(cat, "correct", args);
    }
    if (n === "7") {
      const fid = await ask("feature_id for perf label: ");
      if (!fid) {
        console.error("feature_id required");
        return 2;
      }
      const mode = (await ask("mode [zig|ts|all] (default zig): ")) || "zig";
      return runCommand(cat, "measure", [fid, mode]);
    }
    if (n === "5") {
      const cats = sortedCategories(cat);
      console.log("\nCategories:");
      cats.forEach((c, i) => console.log(`  ${i + 1}) ${c.label}`));
      const ci = await ask("Category #: ");
      const catIdx = Number(ci) - 1;
      if (!cats[catIdx]) {
        console.error("Invalid category");
        return 2;
      }
      const cmds = byCategory(cat).get(cats[catIdx].id) ?? [];
      console.log(`\n${cats[catIdx].label}:`);
      cmds.forEach((c, i) => console.log(`  ${i + 1}) ${c.id} — ${c.title}`));
      const ji = await ask("Command #: ");
      const cmd = cmds[Number(ji) - 1];
      if (!cmd) {
        console.error("Invalid command");
        return 2;
      }
      showCommand(cat, cmd.id);
      const run = await ask("Run it now? [y/N]: ");
      if (run.toLowerCase() !== "y" && run.toLowerCase() !== "yes") return 0;
      const extra: string[] = [];
      for (const a of cmd.args ?? []) {
        if (a.flag) {
          const f = await ask(`${a.name}? [y/N]: `);
          if (f.toLowerCase() === "y" || f.toLowerCase() === "yes") extra.push(a.name);
          continue;
        }
        const prompt = `${a.name}${a.required ? " (required)" : " (optional)"}${a.default != null ? ` [${a.default}]` : ""}${a.hint ? ` — ${a.hint}` : ""}: `;
        const val = await ask(prompt);
        if (val) {
          if (a.name.startsWith("--")) {
            extra.push(a.name, val);
          } else {
            extra.push(val);
          }
        } else if (a.required && a.default == null) {
          console.error(`Missing required ${a.name}`);
          return 2;
        }
      }
      return runCommand(cat, cmd.id, extra);
    }
    console.error("Unknown choice");
    return 2;
  } finally {
    rl.close();
  }
}

function usage() {
  console.log(`MathZig Developer Hub

Usage:
  bun run hub                         Interactive menu
  bun run hub list [category]         List commands
  bun run hub show <id>               Details, args, env, artifacts
  bun run hub run <id> -- [args…]     Run a command
  bun run hub workflow e2e-progress -- <feature_id> [baseline]
  bun run hub where                   Data locations
  bun run hub env                     Env vars
  bun run hub protocol                Agents.md order
  bun run hub docs                    Write docs/COMMANDS.md
  bun run hub help                    This help
`);
}

async function main() {
  const cat = loadCatalog();
  const argv = process.argv.slice(2);
  const cmd = argv[0];

  if (!cmd) {
    const code = await interactive(cat);
    process.exit(code);
  }

  if (cmd === "help" || cmd === "-h" || cmd === "--help") {
    usage();
    process.exit(0);
  }
  if (cmd === "list" || cmd === "ls") {
    listCommands(cat, argv[1]);
    process.exit(0);
  }
  if (cmd === "show" || cmd === "info") {
    if (!argv[1]) {
      console.error("Usage: bun run hub show <command-id>");
      process.exit(2);
    }
    showCommand(cat, argv[1]);
    process.exit(0);
  }
  if (cmd === "where" || cmd === "data") {
    showWhere(cat);
    process.exit(0);
  }
  if (cmd === "env") {
    showEnv(cat);
    process.exit(0);
  }
  if (cmd === "protocol") {
    showProtocol(cat);
    process.exit(0);
  }
  if (cmd === "docs") {
    writeDocs(cat);
    process.exit(0);
  }
  if (cmd === "run") {
    const id = argv[1];
    if (!id) {
      console.error("Usage: bun run hub run <command-id> -- [args…]");
      process.exit(2);
    }
    const dd = argv.indexOf("--");
    const extra = dd >= 0 ? argv.slice(dd + 1) : argv.slice(2);
    process.exit(runCommand(cat, id, extra));
  }
  if (cmd === "workflow") {
    const id = argv[1] ?? "e2e-progress";
    const c = findCommand(cat, id);
    if (!c?.workflow) {
      console.error(`Not a workflow: ${id}`);
      process.exit(2);
    }
    const dd = argv.indexOf("--");
    const extra = dd >= 0 ? argv.slice(dd + 1) : argv.slice(2);
    process.exit(runWorkflow(cat, c, extra));
  }

  // bare id shortcut: bun run hub feature-gate
  if (findCommand(cat, cmd)) {
    const dd = argv.indexOf("--");
    const extra = dd >= 0 ? argv.slice(dd + 1) : argv.slice(1);
    process.exit(runCommand(cat, cmd, extra));
  }

  console.error(`Unknown: ${cmd}`);
  usage();
  process.exit(2);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
