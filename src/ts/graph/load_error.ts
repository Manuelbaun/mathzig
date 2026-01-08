/**
 * Typed error model for untrusted-input surfaces (task-14 / C3).
 *
 * Shape shared with C2 load-error goldens (`error_code` ≡ `code`,
 * `offending` ≡ `context.node` / `context.edge`). Extend, don't fork.
 *
 *   { phase, code, position (byte/line-col or schema path), context, message }
 */

/** Trust boundary phase (one of the four surfaces). */
export type TrustSurfacePhase = "dsl" | "wire" | "manifest" | "graph_json";

/** Byte offset and/or line-col and/or JSON schema path. */
export type ErrorPosition = {
  /** 0-based byte (or UTF-16 code unit) offset into the source. */
  byte?: number;
  line?: number;
  col?: number;
  /** JSON / schema path, e.g. `nodes[3].expr` or `inputs[1].name`. */
  path?: string;
};

/** Offending structural location when known. */
export type ErrorContext = {
  node?: string;
  edge?: string;
  port?: string;
  field?: string;
};

/** Serializable load/parse failure (goldens + harnesses consume this). */
export type LoadErrorShape = {
  phase: TrustSurfacePhase;
  code: string;
  position?: ErrorPosition;
  context?: ErrorContext;
  message: string;
};

/**
 * Base typed error for all four untrusted surfaces.
 * `name` stays surface-specific on subclasses (DslError, WireDecodeError, …)
 * so existing `instanceof` / message checks keep working.
 */
export class MathZigLoadError extends Error {
  readonly phase: TrustSurfacePhase;
  readonly code: string;
  readonly position?: ErrorPosition;
  readonly context?: ErrorContext;

  constructor(
    phase: TrustSurfacePhase,
    code: string,
    message: string,
    opts?: { position?: ErrorPosition; context?: ErrorContext; cause?: unknown },
  ) {
    super(message);
    this.name = "MathZigLoadError";
    this.phase = phase;
    this.code = code;
    this.position = opts?.position;
    this.context = opts?.context;
    if (opts?.cause !== undefined) {
      (this as Error & { cause?: unknown }).cause = opts.cause;
    }
  }

  /** Golden / harness payload (C2-compatible fields derived). */
  toShape(): LoadErrorShape {
    return {
      phase: this.phase,
      code: this.code,
      position: this.position,
      context: this.context,
      message: this.message,
    };
  }

  /** C2 golden fields: error_code + offending. */
  toGoldenFields(): { error_code: string; offending?: string } {
    const offending =
      this.context?.node ?? this.context?.edge ?? this.context?.port ?? this.context?.field;
    return offending
      ? { error_code: this.code, offending }
      : { error_code: this.code };
  }
}

export class WireDecodeError extends MathZigLoadError {
  constructor(
    code: string,
    message: string,
    opts?: { position?: ErrorPosition; context?: ErrorContext; cause?: unknown },
  ) {
    super("wire", code, message, opts);
    this.name = "WireDecodeError";
  }
}

export class ManifestLoadError extends MathZigLoadError {
  constructor(
    code: string,
    message: string,
    opts?: { position?: ErrorPosition; context?: ErrorContext; cause?: unknown },
  ) {
    super("manifest", code, message, opts);
    this.name = "ManifestLoadError";
  }
}

export class GraphJsonError extends MathZigLoadError {
  constructor(
    code: string,
    message: string,
    opts?: { position?: ErrorPosition; context?: ErrorContext; cause?: unknown },
  ) {
    super("graph_json", code, message, opts);
    this.name = "GraphJsonError";
  }
}

/** Best-effort extract of LoadErrorShape from any thrown value. */
export function loadErrorShapeOf(err: unknown): LoadErrorShape | null {
  if (err instanceof MathZigLoadError) return err.toShape();
  if (err && typeof err === "object") {
    const e = err as Record<string, unknown>;
    if (typeof e.phase === "string" && typeof e.code === "string" && typeof e.message === "string") {
      return {
        phase: e.phase as TrustSurfacePhase,
        code: e.code,
        position: e.position as ErrorPosition | undefined,
        context: e.context as ErrorContext | undefined,
        message: e.message,
      };
    }
  }
  return null;
}
