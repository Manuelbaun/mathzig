/**
 * Externally enforced deadline for pathological-input cases (task-14 / C3).
 *
 * Sync elapsed-time asserts cannot stop a hung parser — run work in a child
 * process and kill on deadline. Deadline kill = test failure.
 */

import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

export type DeadlineResult =
  | { ok: true; stdout: string; stderr: string; ms: number }
  | { ok: false; reason: "timeout" | "nonzero" | "spawn"; stdout: string; stderr: string; ms: number; status: number | null };

/**
 * Run `bun <script> ...args` with an external deadline (ms).
 * On timeout the child is SIGKILL'd and result.reason === "timeout".
 */
export function runChildWithDeadline(
  scriptRelative: string,
  args: string[],
  deadlineMs: number,
  cwd: string = process.cwd(),
): DeadlineResult {
  const script = resolve(cwd, scriptRelative);
  const t0 = performance.now();
  const r = spawnSync("bun", [script, ...args], {
    cwd,
    encoding: "utf8",
    timeout: deadlineMs,
    killSignal: "SIGKILL",
    maxBuffer: 4 * 1024 * 1024,
  });
  const ms = performance.now() - t0;
  const stdout = r.stdout ?? "";
  const stderr = r.stderr ?? "";
  if (r.error && (r.error as NodeJS.ErrnoException).code === "ETIMEDOUT") {
    return { ok: false, reason: "timeout", stdout, stderr, ms, status: null };
  }
  if (r.error) {
    return { ok: false, reason: "spawn", stdout, stderr: String(r.error), ms, status: null };
  }
  if (r.status !== 0) {
    return { ok: false, reason: "nonzero", stdout, stderr, ms, status: r.status };
  }
  return { ok: true, stdout, stderr, ms };
}

/** Assert child finished under deadline without hang. */
export function assertChildFinishes(
  scriptRelative: string,
  args: string[],
  deadlineMs: number,
): void {
  const r = runChildWithDeadline(scriptRelative, args, deadlineMs);
  if (!r.ok && r.reason === "timeout") {
    throw new Error(
      `adversarial deadline: child hung / exceeded ${deadlineMs}ms (${scriptRelative} ${args.join(" ")})`,
    );
  }
  if (!r.ok) {
    throw new Error(
      `adversarial child failed (${r.reason}, status=${r.status}): ${r.stderr || r.stdout}`,
    );
  }
}
