/**
 * Run rocket-demo expressions through WASM toLaTeX + KaTeX and report failures.
 *
 * Usage (from apps/console):
 *   bun scripts/rocket_latex_audit.ts
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import katex from "katex";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const WASM_PATH = join(ROOT, "public/mathzig_wasm.wasm");
const OUT_DIR = join(ROOT, "../../tmp");
const OUT_JSON = join(OUT_DIR, "rocket_latex_errors.json");
const OUT_MD = join(OUT_DIR, "rocket_latex_errors.md");

type Row = {
  i: number;
  phase: string;
  expr: string;
  evalOk: boolean;
  evalValue?: string;
  evalError?: string;
  latex: string | null;
  latexGenOk: boolean;
  katexOk: boolean;
  katexError?: string;
};

async function main() {
  const wasmBuf = readFileSync(WASM_PATH);
  const { instance } = await WebAssembly.instantiate(wasmBuf, {});
  const w = instance.exports as any;
  const mem = w.memory as WebAssembly.Memory;
  const enc = new TextEncoder();
  const dec = new TextDecoder();

  function allocString(str: string): number {
    const bytes = enc.encode(str + "\0");
    const ptr = w.wasm_malloc(bytes.length);
    if (!ptr) throw new Error("wasm_malloc failed");
    new Uint8Array(mem.buffer, ptr, bytes.length).set(bytes);
    return ptr;
  }
  function freeString(ptr: number, str: string) {
    const bytes = enc.encode(str + "\0");
    w.wasm_free(ptr, bytes.length);
  }
  function readString(ptr: number): string {
    if (!ptr) return "";
    const view = new Uint8Array(mem.buffer, ptr);
    let end = 0;
    while (view[end] !== 0 && end < 100_000) end++;
    return dec.decode(view.subarray(0, end));
  }

  const ctx = w.mathzig_create();
  if (!ctx) throw new Error("mathzig_create failed");

  function evaluate(expr: string): { ok: boolean; value?: string; error?: string } {
    const p = allocString(expr);
    try {
      // Match apps/console runtime: mathzig_eval
      w.mathzig_eval(ctx, p);
      const lastTag = w.mathzig_get_last_tag ? (w.mathzig_get_last_tag() as number) : -1;
      let value = "";
      if (w.mathzig_format_last_value) {
        const bp = w.wasm_malloc(2048);
        const n = w.mathzig_format_last_value(ctx, bp, 2048) as number;
        value = n > 0 ? readString(bp) : "";
        w.wasm_free(bp, 2048);
      }
      const errorStr = w.mathzig_get_error ? readString(w.mathzig_get_error(ctx)) : "";
      // Tag 9 is often err in MathZig value tags — also empty value + error
      if ((lastTag === 9 || lastTag === 255) && errorStr) {
        return { ok: false, error: errorStr, value };
      }
      if (!value && errorStr) return { ok: false, error: errorStr };
      return { ok: true, value: value || `(tag=${lastTag})` };
    } finally {
      freeString(p, expr);
    }
  }

  function toLaTeX(expr: string): { ok: boolean; latex: string | null; error?: string } {
    const p = allocString(expr);
    try {
      const lp = w.mathzig_to_latex(ctx, p) as number;
      if (!lp) {
        const err = w.mathzig_get_error ? readString(w.mathzig_get_error(ctx)) : "null latex ptr";
        return { ok: false, latex: null, error: err || "toLaTeX returned null" };
      }
      const latex = readString(lp);
      if (!latex) return { ok: false, latex: null, error: "empty latex" };
      if (latex.includes("unsupported:")) {
        return { ok: false, latex, error: "engine unsupported node in latex" };
      }
      return { ok: true, latex };
    } finally {
      freeString(p, expr);
    }
  }

  function tryKatex(latex: string): { ok: boolean; error?: string } {
    try {
      katex.renderToString(latex, {
        throwOnError: true,
        displayMode: false,
        strict: "ignore",
        trust: false,
      });
      return { ok: true };
    } catch (e: any) {
      return { ok: false, error: e?.message || String(e) };
    }
  }

  const staticSteps = [
    "G = 6.67408e-11 m^3 / (kg * s^2)",
    "mbody = 5.9724e24 kg",
    "mu = G * mbody",
    "g0 = 9.80665 m/s^2",
    "r0 = 6371 km",
    "isp_sea = 282 s",
    "isp_vac = 311 s",
    "gamma0 = 89.99970 deg",
    "v0 = 1 m/s",
    "phi0 = 0 deg",
    "m1 = 433100 kg",
    "m2 = 111500 kg",
    "m3 = 1700 kg",
    "mp = 5000 kg",
    "m0 = m1+m2+m3+mp",
    "dm = 2750 kg/s",
    "A = (3.66 m)^2 * pi",
    "dragCoef = 0.2",
    "mu_v = conv(mu, m^3/s^2)",
    "g0_v = conv(g0, m/s^2)",
    "r0_v = conv(r0, m)",
    "dm_v = conv(dm, kg/s)",
    "A_v = conv(A, m^2)",
    "isp_sea_v = conv(isp_sea, s)",
    "isp_vac_v = conv(isp_vac, s)",
    "density_v(r) = 1.2250 * exp(-g0_v * (r - r0_v) / 83246.8)",
    "isp_v(r) = isp_vac_v + (isp_sea_v - isp_vac_v) * density_v(r)/density_v(r0_v)",
    "thrust_v(isp) = g0_v * isp * dm_v",
    "drag_v(r, v) = 1/2 * density_v(r) * v^2 * A_v * dragCoef",
    "rad = 1",
    "rocket_deriv(t, y) = [y[1, 0] * sin(y[4, 0]); -mu_v / y[0, 0]^2 * sin(y[4, 0]) + (thrust_v(isp_v(y[0, 0])) - drag_v(y[0, 0], y[1, 0])) / y[2, 0]; -dm_v; y[1, 0]/y[0, 0] * cos(y[4, 0]) * rad; (y[1, 0]/y[0, 0] * cos(y[4, 0]) - (mu_v / y[0, 0]^2) * cos(y[4, 0]) / y[1, 0]) * rad]",
    "tfinal = 149.5",
    "y0 = [r0_v; v0; m0; phi0; gamma0]",
    'result_stage1 = ode_solve_euler("rocket_deriv", y0, [0, tfinal], 2.0)',
  ];

  const rows: Row[] = [];
  let i = 0;

  function process(phase: string, expr: string) {
    const ev = evaluate(expr);
    const lx = toLaTeX(expr);
    let katexOk = false;
    let katexError: string | undefined;
    if (lx.latex) {
      const k = tryKatex(lx.latex);
      katexOk = k.ok;
      katexError = k.error;
    } else {
      katexError = lx.error || "no latex";
    }
    rows.push({
      i: i++,
      phase,
      expr,
      evalOk: ev.ok,
      evalValue: ev.value,
      evalError: ev.error,
      latex: lx.latex,
      latexGenOk: lx.ok,
      katexOk,
      katexError: katexOk ? undefined : katexError || lx.error,
    });
  }

  for (const expr of staticSteps) process("stage1", expr);

  const rows1Ev = evaluate("size(result_stage1).rows");
  // format may be plain number string
  const r1 = Number(String(rows1Ev.value ?? "").replace(/[^\d.-]/g, "")) || 0;
  console.log("result_stage1 rows ≈", r1, rows1Ev);

  if (r1 > 0) {
    const interstage = [
      "t_inter = 10",
      `x1 = [result_stage1[${r1 - 1}, 1]; result_stage1[${r1 - 1}, 2]; conv(m2 + m3 + mp, kg); result_stage1[${r1 - 1}, 4]; result_stage1[${r1 - 1}, 5]]`,
      `t1 = result_stage1[${r1 - 1}, 0]`,
      'rocket_deriv_inter(t, y) = [y[1, 0] * sin(max(0, y[4, 0])); -mu_v / y[0, 0]^2 * sin(max(0, y[4, 0])) - drag_v(y[0, 0], y[1, 0]) / y[2, 0]; 0; y[1, 0]/y[0, 0] * cos(y[4, 0]); (y[1, 0]/y[0, 0] - mu_v / (y[0, 0]^2 * y[1, 0])) * cos(y[4, 0])]',
      'result_interstage = ode_solve_euler("rocket_deriv_inter", x1, [t1, t1 + t_inter], 2.0)',
    ];
    for (const expr of interstage) process("interstage", expr);

    const rowsIEv = evaluate("size(result_interstage).rows");
    const ri = Number(String(rowsIEv.value ?? "").replace(/[^\d.-]/g, "")) || 0;
    console.log("result_interstage rows ≈", ri, rowsIEv);

    if (ri > 0) {
      const stage2 = [
        "t_s2 = 397",
        `x2 = [result_interstage[${ri - 1}, 1]; result_interstage[${ri - 1}, 2]; result_interstage[${ri - 1}, 3]; result_interstage[${ri - 1}, 4]; result_interstage[${ri - 1}, 5]]`,
        `t2 = result_interstage[${ri - 1}, 0]`,
        'rocket_deriv_s2(t, y) = [y[1, 0] * sin(max(0, y[4, 0])); -mu_v / y[0, 0]^2 * sin(max(0, y[4, 0])) + (g0_v * 348 * 270.8 - drag_v(y[0, 0], y[1, 0])) / y[2, 0]; -270.8; y[1, 0]/y[0, 0] * cos(y[4, 0]); (y[1, 0]/y[0, 0] - mu_v / (y[0, 0]^2 * y[1, 0])) * cos(y[4, 0])]',
        'result_stage2 = ode_solve_euler("rocket_deriv_s2", x2, [t2, t2 + t_s2], 4.0)',
      ];
      for (const expr of stage2) process("stage2", expr);
    }
  }

  const failures = rows.filter((r) => !r.katexOk);
  const buckets = new Map<string, number>();
  for (const f of failures) {
    const msg = f.katexError || "unknown";
    const key = msg
      .replace(/at position \d+:/g, "at position N:")
      .replace(/KaTeX parse error: /g, "")
      .slice(0, 160);
    buckets.set(key, (buckets.get(key) || 0) + 1);
  }

  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(
    OUT_JSON,
    JSON.stringify(
      {
        summary: {
          total: rows.length,
          evalOk: rows.filter((r) => r.evalOk).length,
          latexGenOk: rows.filter((r) => r.latexGenOk).length,
          katexOk: rows.filter((r) => r.katexOk).length,
          katexFail: failures.length,
        },
        errorBuckets: Object.fromEntries([...buckets.entries()].sort((a, b) => b[1] - a[1])),
        failures,
        all: rows,
      },
      null,
      2,
    ),
  );

  const md: string[] = [];
  md.push("# Rocket LaTeX audit");
  md.push("");
  md.push(`WASM: \`${WASM_PATH}\``);
  md.push("");
  md.push("## Summary");
  md.push("");
  md.push(`| metric | count |`);
  md.push(`|--------|------:|`);
  md.push(`| expressions | ${rows.length} |`);
  md.push(`| eval ok | ${rows.filter((r) => r.evalOk).length} |`);
  md.push(`| latex gen ok | ${rows.filter((r) => r.latexGenOk).length} |`);
  md.push(`| katex ok | ${rows.filter((r) => r.katexOk).length} |`);
  md.push(`| **katex fail** | **${failures.length}** |`);
  md.push("");
  md.push("## Error buckets");
  md.push("");
  for (const [k, n] of [...buckets.entries()].sort((a, b) => b[1] - a[1])) {
    md.push(`- **${n}×** \`${k}\``);
  }
  md.push("");
  md.push("## Failures (detail)");
  md.push("");
  for (const f of failures) {
    md.push(`### #${f.i} [${f.phase}]`);
    md.push("");
    md.push("**expr**");
    md.push("```");
    md.push(f.expr);
    md.push("```");
    md.push("");
    md.push("**latex**");
    md.push("```latex");
    md.push(f.latex ?? "(null)");
    md.push("```");
    md.push("");
    md.push(`**katex error:** ${f.katexError}`);
    md.push("");
  }
  writeFileSync(OUT_MD, md.join("\n"));

  console.log("Wrote", OUT_JSON);
  console.log("Wrote", OUT_MD);
  console.log(
    JSON.stringify(
      {
        total: rows.length,
        katexOk: rows.filter((r) => r.katexOk).length,
        katexFail: failures.length,
        buckets: Object.fromEntries(buckets),
      },
      null,
      2,
    ),
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
