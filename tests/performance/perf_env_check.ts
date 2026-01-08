import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

type Finding = {
  id: string;
  severity: "info" | "warn" | "error";
  message: string;
  details?: string;
};

const featureId = process.argv[2] ?? "baseline";
const strict = process.env.PERF_ENV_STRICT === "1";
const outDir = path.resolve(process.cwd(), "tests/artifacts/performance/env_checks");
const outFile = path.join(outDir, `${featureId}.json`);

function run(cmd: string[]) {
  try {
    const res = Bun.spawnSync({ cmd, stdout: "pipe", stderr: "pipe" });
    const stdout = new TextDecoder().decode(res.stdout ?? new Uint8Array());
    const stderr = new TextDecoder().decode(res.stderr ?? new Uint8Array());
    return { exit: res.exitCode ?? 1, stdout, stderr };
  } catch (err) {
    return { exit: 1, stdout: "", stderr: String(err) };
  }
}

function hasTool(name: string): boolean {
  return Bun.which(name) != null;
}

function topCpuProcesses(limit = 8) {
  if (!hasTool("ps")) return [] as Array<{ cpu: number; cmd: string }>;
  const out = run(["ps", "-A", "-o", "%cpu=,comm="]).stdout;
  const rows = out
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const m = line.match(/^([0-9.]+)\s+(.+)$/);
      if (!m) return null;
      return { cpu: Number(m[1]), cmd: m[2] };
    })
    .filter((r): r is { cpu: number; cmd: string } => !!r && Number.isFinite(r.cpu))
    .sort((a, b) => b.cpu - a.cpu)
    .slice(0, limit);
  return rows;
}

function checkBatteryLowPowerMode(findings: Finding[]) {
  if (process.platform !== "darwin" || !hasTool("pmset")) return;
  const out = run(["pmset", "-g"]).stdout;
  const m = out.match(/\blowpowermode\s+(\d)/i);
  if (m && m[1] === "1") {
    findings.push({
      id: "mac_low_power_mode",
      severity: "warn",
      message: "macOS Low Power Mode is enabled; perf can be throttled.",
    });
  }
}

function checkLoadAverage(findings: Finding[]) {
  const cpus = Math.max(1, os.cpus().length);
  const load1 = os.loadavg()[0];
  const normalized = load1 / cpus;
  if (normalized > 0.9) {
    findings.push({
      id: "high_load",
      severity: "error",
      message: `High current CPU load (${load1.toFixed(2)} on ${cpus} cores).`,
      details: "Close background workloads before perf run.",
    });
  } else if (normalized > 0.6) {
    findings.push({
      id: "elevated_load",
      severity: "warn",
      message: `Elevated current CPU load (${load1.toFixed(2)} on ${cpus} cores).`,
      details: "Results may be noisy.",
    });
  }
}

function checkTopProcesses(findings: Finding[]) {
  const top = topCpuProcesses();
  if (top.length === 0) {
    findings.push({
      id: "top_process_unavailable",
      severity: "info",
      message: "Top-process CPU check unavailable in this environment.",
    });
    return;
  }
  const busy = top.filter((p) => p.cpu >= 30);
  if (busy.length > 0) {
    findings.push({
      id: "busy_processes",
      severity: "warn",
      message: `Found ${busy.length} high-CPU process(es) >=30%.`,
      details: busy.map((p) => `${p.cpu.toFixed(1)}% ${p.cmd}`).join("; "),
    });
  }
}

function checkPerfFlags(findings: Finding[]) {
  if (!process.env.PERF_SAMPLES) {
    findings.push({
      id: "samples_default",
      severity: "info",
      message: "PERF_SAMPLES not set (runner default applies).",
      details: "Set PERF_SAMPLES=7 for more stable comparisons.",
    });
  }
  if (!process.env.PERF_WARMUP) {
    findings.push({
      id: "warmup_default",
      severity: "info",
      message: "PERF_WARMUP not set (runner default applies).",
      details: "Set PERF_WARMUP=2 for stable baseline temperature/state.",
    });
  }
}

const findings: Finding[] = [];
checkLoadAverage(findings);
checkTopProcesses(findings);
checkBatteryLowPowerMode(findings);
checkPerfFlags(findings);

const payload = {
  featureId,
  strict,
  checkedAt: new Date().toISOString(),
  host: {
    platform: process.platform,
    arch: process.arch,
    cpuModel: os.cpus()[0]?.model ?? "unknown",
    cpuCores: os.cpus().length,
    loadavg1: os.loadavg()[0],
  },
  findings,
};

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(outFile, `${JSON.stringify(payload, null, 2)}\n`, "utf8");

if (findings.length === 0) {
  console.log(`Perf env check: OK (${path.relative(process.cwd(), outFile)})`);
  process.exit(0);
}

console.log(`Perf env check: ${findings.length} finding(s) (${path.relative(process.cwd(), outFile)})`);
for (const f of findings) {
  console.log(`- [${f.severity}] ${f.message}${f.details ? ` (${f.details})` : ""}`);
}

const hasError = findings.some((f) => f.severity === "error");
const hasWarn = findings.some((f) => f.severity === "warn");
if (strict && (hasError || hasWarn)) {
  process.exit(1);
}
process.exit(0);
