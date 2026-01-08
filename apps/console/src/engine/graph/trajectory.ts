/**
 * Extract rocket-style trajectory series from graph matrix outputs
 * (ODE results: columns [t, r, v, m, phi, gamma, ...]).
 */

import type { GraphValue } from "@mathzig/graph";
import type { TrajectoryData } from "../demos/rocket";
import type { FormattedGraphValue } from "./format";

export const EARTH_RADIUS_M = 6_371_000;

export type MatrixCells = {
  rows: number;
  cols: number;
  data: number[];
};

/** True when matrix looks like multi-step ODE output with time + state. */
export function isOdeTrajectoryMatrix(m: MatrixCells, minRows = 2): boolean {
  return m.rows >= minRows && m.cols >= 6;
}

export function matrixFromFormatted(f: FormattedGraphValue): MatrixCells | null {
  return f.matrix ?? null;
}

export function matrixFromGraphValue(value: GraphValue): MatrixCells | null {
  if (!value || typeof value !== "object") return null;
  if (!("rows" in value && "cols" in value && "data" in value)) return null;
  const rows = Number((value as { rows: number }).rows);
  const cols = Number((value as { cols: number }).cols);
  const raw = (value as { data: ArrayLike<number> }).data;
  if (!Number.isFinite(rows) || !Number.isFinite(cols) || rows < 1 || cols < 1) return null;
  const data: number[] = [];
  for (let i = 0; i < rows * cols; i++) data.push(Number(raw[i]));
  return { rows, cols, data };
}

/**
 * One ODE matrix → trajectory series.
 * col0=t, col1=r (m), col2=v, col5=gamma (rad).
 */
export function rocketTrajectoryFromMatrix(
  m: MatrixCells,
  r0: number = EARTH_RADIUS_M,
): TrajectoryData | null {
  if (!isOdeTrajectoryMatrix(m)) return null;
  const time: number[] = [];
  const altitude: number[] = [];
  const velocity: number[] = [];
  const gamma: number[] = [];
  for (let r = 0; r < m.rows; r++) {
    const base = r * m.cols;
    time.push(m.data[base]!);
    altitude.push((m.data[base + 1]! - r0) / 1000);
    velocity.push(m.data[base + 2]!);
    gamma.push((m.data[base + 5]! * 180) / Math.PI);
  }
  return { time, altitude, velocity, gamma };
}

export function concatTrajectories(parts: TrajectoryData[]): TrajectoryData | null {
  if (parts.length === 0) return null;
  const out: TrajectoryData = { time: [], altitude: [], velocity: [], gamma: [] };
  for (const p of parts) {
    out.time.push(...p.time);
    out.altitude.push(...p.altitude);
    out.velocity.push(...p.velocity);
    out.gamma.push(...p.gamma);
  }
  return out.time.length > 0 ? out : null;
}

/**
 * Prefer named stage matrices (trajectory*, stage*, inter*), then any ODE-shaped
 * matrix outputs. Concatenates in sorted name order so s1 → inter → s2 is stable.
 */
/** Stage order for multi-part rocket (lower = earlier). */
function trajectoryStageScore(name: string): number {
  const n = name.toLowerCase();
  // Specific stage tokens first (before generic "trajectory").
  if (/(stage\s*1|_s1\b|s1\b)/.test(n) || n.includes("stage1")) return 1;
  if (n.includes("inter")) return 2;
  if (/(stage\s*2|_s2\b|s2\b)/.test(n) || n.includes("stage2")) return 3;
  if (/(stage\s*3|_s3\b|s3\b)/.test(n) || n.includes("stage3")) return 4;
  if (n.includes("trajectory") || n.includes("traj") || n.includes("stage")) return 5;
  return 10;
}

export function trajectoryFromGraphOutputs(
  outputs: Record<string, GraphValue>,
  r0: number = EARTH_RADIUS_M,
): TrajectoryData | null {
  const entries = Object.entries(outputs);
  const scored: Array<{ name: string; score: number; m: MatrixCells }> = [];
  for (const [name, value] of entries) {
    const m = matrixFromGraphValue(value);
    if (!m || !isOdeTrajectoryMatrix(m)) continue;
    scored.push({ name, score: trajectoryStageScore(name), m });
  }
  if (scored.length === 0) return null;
  scored.sort((a, b) => a.score - b.score || a.name.localeCompare(b.name));
  // Prefer named stage/trajectory matrices; otherwise first ODE-shaped matrix.
  const preferred = scored.filter((s) => s.score <= 5);
  const use = preferred.length > 0 ? preferred : scored.slice(0, 1);
  const parts: TrajectoryData[] = [];
  for (const s of use) {
    const t = rocketTrajectoryFromMatrix(s.m, r0);
    if (t) parts.push(t);
  }
  return concatTrajectories(parts);
}

export function trajectoryFromFormattedOutputs(
  outputs: Array<{ name: string; formatted: FormattedGraphValue }>,
  r0: number = EARTH_RADIUS_M,
): TrajectoryData | null {
  const asValues: Record<string, GraphValue> = {};
  for (const o of outputs) {
    const m = o.formatted.matrix;
    if (m) asValues[o.name] = m;
  }
  return trajectoryFromGraphOutputs(asValues, r0);
}
