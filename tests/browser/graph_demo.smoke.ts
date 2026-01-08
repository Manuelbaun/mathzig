#!/usr/bin/env bun
/**
 * task-17 / C6 — Playwright chromium smoke for web/graph_demo.html
 *
 * Tag class: **smoke** (same role as task-16 `soak`):
 *   - excluded from quick gate (`bun run mz -- --quick`)
 *   - included in full protocol (`bun run mz`) as pipeline step `browser_smoke`
 *
 * Exact commands:
 *   export PATH="$PWD/tools/macos-sdk-shim:$PATH"
 *   zig build                              # mathzig for /api/aot_compile
 *   bun tools/build_graph_bundle.ts        # web/graph_bundle.js
 *   bun tests/browser/graph_demo.smoke.ts  # this file (starts demo server)
 *
 * Or via full pipeline (after correctness):
 *   bun run mz
 *
 * Assertions (real Chromium, real demo architecture with Bun /api/aot_compile):
 *   1. page loads with zero console errors
 *   2. example graph loads (status ready)
 *   3. one tick produces a rendered output value
 *   4. moving one param slider changes the next tick's output
 *
 * Architecture note: demo uses POST /api/aot_compile (native mathzig), not the
 * static MathZigWasm-only path task-09 originally specified — product decision;
 * smoke targets AS-IS. See web/README.md.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { chromium, type Browser, type ConsoleMessage } from "playwright";

const ROOT = path.resolve(import.meta.dir, "../..");
const PORT = Number(process.env.GRAPH_DEMO_SMOKE_PORT || "8791");
const BASE = `http://127.0.0.1:${PORT}`;

function ensureBundle(): void {
  const bundle = path.join(ROOT, "web/graph_bundle.js");
  if (fs.existsSync(bundle) && fs.statSync(bundle).size > 0) return;
  console.log("Building web/graph_bundle.js…");
  const r = Bun.spawnSync({
    cmd: ["bun", path.join(ROOT, "tools/build_graph_bundle.ts")],
    cwd: ROOT,
    stdout: "inherit",
    stderr: "inherit",
    env: process.env,
  });
  if (r.exitCode !== 0) {
    throw new Error("build_graph_bundle failed");
  }
}

function ensureMathzig(): void {
  const bin = path.join(ROOT, "zig-out/bin/mathzig");
  if (fs.existsSync(bin)) return;
  console.log("zig-out/bin/mathzig missing — running zig build…");
  const r = Bun.spawnSync({
    cmd: ["zig", "build"],
    cwd: ROOT,
    stdout: "inherit",
    stderr: "inherit",
    env: process.env,
  });
  if (r.exitCode !== 0) {
    throw new Error("zig build failed (needed for /api/aot_compile)");
  }
}

async function startServer(): Promise<ReturnType<typeof Bun.spawn>> {
  ensureBundle();
  ensureMathzig();
  const proc = Bun.spawn({
    cmd: ["bun", path.join(ROOT, "web/graph_demo_server.ts")],
    cwd: ROOT,
    env: { ...process.env, PORT: String(PORT) },
    stdout: "pipe",
    stderr: "pipe",
  });
  // Wait until compile API answers
  const deadline = Date.now() + 30_000;
  let lastErr = "";
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${BASE}/api/aot_compile?params=0`, {
        method: "POST",
        body: "1+1",
      });
      if (res.ok) return proc;
      lastErr = await res.text();
    } catch (e) {
      lastErr = String(e);
    }
    await Bun.sleep(200);
  }
  proc.kill();
  throw new Error(`demo server did not become ready: ${lastErr}`);
}

function parseOutputNumber(text: string): number | null {
  // outputs look like: value  <span>…</span> filtered …
  const m = text.match(/-?\d+(?:\.\d+)?(?:e[+-]?\d+)?/i);
  if (!m) return null;
  const n = Number(m[0]);
  return Number.isFinite(n) ? n : null;
}

async function runSmoke(): Promise<void> {
  let browser: Browser | null = null;
  let server: ReturnType<typeof Bun.spawn> | null = null;
  const consoleErrors: string[] = [];
  const pageErrors: string[] = [];

  try {
    server = await startServer();
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();

    page.on("console", (msg: ConsoleMessage) => {
      if (msg.type() === "error") {
        consoleErrors.push(msg.text());
      }
    });
    page.on("pageerror", (err) => {
      pageErrors.push(String(err?.message ?? err));
    });

    // Use "load" not "networkidle": demo modules + compile probe can keep the
    // network busy past Playwright's idle window on cold AOT.
    await page.goto(`${BASE}/graph_demo.html`, {
      waitUntil: "load",
      timeout: 60_000,
    });

    // Wait for compile probe or ready
    await page.waitForFunction(
      () => {
        const s = document.querySelector('[data-testid="status"]');
        const t = (s?.textContent || "").toLowerCase();
        return t.includes("compiler ok") || t.includes("ready") || t.includes("error");
      },
      { timeout: 30_000 }
    );

    const status0 = (await page.locator('[data-testid="status"]').textContent()) || "";
    if (status0.toLowerCase().includes("no compile")) {
      throw new Error(`compile API unavailable in page: ${status0}`);
    }

    // Example graph is pre-filled; Load
    await page.locator('[data-testid="btn-load"]').click();
    await page.waitForFunction(
      () => {
        const s = document.querySelector('[data-testid="status"]');
        return (s?.textContent || "").toLowerCase().includes("ready");
      },
      { timeout: 60_000 }
    );

    // Load path already ticks once; ensure outputs render
    const outputs = page.locator('[data-testid="outputs"]');
    await outputs.waitFor({ state: "visible", timeout: 10_000 });
    let outText = (await outputs.innerText()).trim();
    if (!outText || outText === "—") {
      await page.locator('[data-testid="btn-tick"]').click();
      outText = (await outputs.innerText()).trim();
    }
    if (!outText || outText === "—" || !/\d/.test(outText)) {
      throw new Error(`expected rendered output value, got: ${JSON.stringify(outText)}`);
    }
    const before = parseOutputNumber(outText);

    // Move first param slider (gain.g or lowpass.a)
    const slider = page.locator('#params input[type="range"]').first();
    await slider.waitFor({ state: "visible", timeout: 10_000 });
    const oldVal = Number(await slider.inputValue());
    // Push slider to max to guarantee a setParam change for gain/lowpass
    const max = Number(await slider.getAttribute("max"));
    const min = Number(await slider.getAttribute("min"));
    const next =
      Number.isFinite(max) && max !== oldVal
        ? max
        : Number.isFinite(min) && min !== oldVal
          ? min
          : oldVal + 1;
    await slider.fill(String(next));
    // fill may not fire "input" on all engines — also dispatch
    await slider.evaluate((el, v) => {
      const input = el as HTMLInputElement;
      input.value = String(v);
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    }, next);

    await page.locator('[data-testid="btn-tick"]').click();
    await page.waitForTimeout(100);
    const afterText = (await outputs.innerText()).trim();
    const after = parseOutputNumber(afterText);

    if (before != null && after != null && before === after && next !== oldVal) {
      // Lowpass with source=0 can stay 0; set source input too then re-tick.
      const sourceSlider = page.locator('#inputs input[type="range"]').first();
      if (await sourceSlider.count()) {
        await sourceSlider.evaluate((el) => {
          const input = el as HTMLInputElement;
          input.value = "10";
          input.dispatchEvent(new Event("input", { bubbles: true }));
        });
        await page.locator('[data-testid="btn-tick"]').click();
        const mid = parseOutputNumber((await outputs.innerText()).trim());
        // change gain param again
        await slider.evaluate((el, v) => {
          const input = el as HTMLInputElement;
          input.value = String(v);
          input.dispatchEvent(new Event("input", { bubbles: true }));
        }, next === max ? min : max);
        await page.locator('[data-testid="btn-tick"]').click();
        const final = parseOutputNumber((await outputs.innerText()).trim());
        if (mid != null && final != null && mid === final) {
          throw new Error(
            `param slider did not change output (mid=${mid}, final=${final}, slider ${oldVal}→…)`
          );
        }
      } else if (before === after) {
        throw new Error(
          `param slider did not change output (before=${before}, after=${after})`
        );
      }
    }

    if (consoleErrors.length > 0) {
      throw new Error(`console errors:\n${consoleErrors.join("\n")}`);
    }
    if (pageErrors.length > 0) {
      throw new Error(`page errors:\n${pageErrors.join("\n")}`);
    }

    console.log("graph_demo.smoke: PASS");
    console.log(`  status after load: ready`);
    console.log(`  outputs sample: ${outText.replace(/\s+/g, " ").slice(0, 120)}`);
    console.log(`  param slider ${oldVal} → ${next}; post-tick outputs changed or source re-tested`);
  } finally {
    if (browser) await browser.close();
    if (server) {
      try {
        server.kill();
      } catch {
        /* ignore */
      }
    }
  }
}

// CLI: bun tests/browser/graph_demo.smoke.ts
// Test runner: bun test tests/browser/graph_demo.smoke.ts
// (import.meta.main is false under `bun test`)
if (import.meta.main) {
  runSmoke()
    .then(() => process.exit(0))
    .catch((err) => {
      console.error("graph_demo.smoke: FAIL", err instanceof Error ? err.message : err);
      process.exit(1);
    });
} else {
  // bun:test integration (tag class: smoke — full protocol only via pipeline)
  const { test } = await import("bun:test");
  test(
    "smoke: graph_demo playwright chromium",
    async () => {
      await runSmoke();
    },
    { timeout: 180_000 }
  );
}
