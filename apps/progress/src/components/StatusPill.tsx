import type { PackageStatus, StepStatus } from "../lib/data";

type StatusKind = PackageStatus | StepStatus | "ok" | "error" | "skipped" | string;

const TONE: Record<string, string> = {
  pass: "bg-ok/15 text-ok border-ok/30",
  ok: "bg-ok/15 text-ok border-ok/30",
  OK: "bg-ok/15 text-ok border-ok/30",
  IMPROVEMENT: "bg-ok/15 text-ok border-ok/30",
  fail: "bg-err/15 text-err border-err/30",
  error: "bg-err/15 text-err border-err/30",
  REGRESSION: "bg-err/15 text-err border-err/30",
  REGRESSION_REL: "bg-err/15 text-err border-err/30",
  REGRESSION_ABS: "bg-err/15 text-err border-err/30",
  partial: "bg-warn/15 text-warn border-warn/30",
  UNSTABLE: "bg-warn/15 text-warn border-warn/30",
  skipped: "bg-raised text-fg-muted border-line",
  done: "bg-ok/15 text-ok border-ok/30",
  broken: "bg-err/15 text-err border-err/30",
  missing: "bg-string/10 text-string border-string/35",
  MISSING_AFTER: "bg-raised text-fg-muted border-line",
  MISSING_BASELINE: "bg-raised text-fg-muted border-line",
  NEW: "bg-raised text-fg-secondary border-line",
  NEW_IN_AFTER: "bg-raised text-fg-secondary border-line",
  // Distinct from missing/skipped: hatched-looking border + muted keyword tint
  unknown: "bg-keyword/10 text-fg-muted border-keyword/40 border-dashed",
  "n/a": "bg-inset text-fg-muted border-line",
};

export function StatusPill(props: {
  status: StatusKind;
  class?: string;
  title?: string;
}) {
  const tone = () =>
    TONE[String(props.status)] ?? "bg-raised text-fg-secondary border-line";
  return (
    <span
      class={`inline-flex items-center rounded border px-1.5 py-0.5 font-mono text-[11px] leading-none ${tone()} ${props.class ?? ""}`}
      title={props.title}
    >
      {String(props.status)}
    </span>
  );
}
