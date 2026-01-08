# Adversarial input hardening (task-14 / C3)

Four untrusted surfaces, each with:

| Surface | Code | Default fuzzer | Regression corpus |
|---------|------|----------------|-------------------|
| **S1** DSL | `src/ts/graph/dsl.ts` | `tests/ts/adversarial/s1_dsl_fuzz.test.ts` | `tests/adversarial/corpus/s1/` |
| **S2** wire-decode | `src/ts/aot_env.ts` | `tests/ts/adversarial/s2_wire_fuzz.test.ts` | `tests/adversarial/corpus/s2/` |
| **S3** manifest | `src/graph/manifest.zig` + TS section readers | `tests/ts/adversarial/s3_manifest_fuzz.test.ts` + Zig | `tests/adversarial/corpus/s3/` |
| **S4** graph JSON | `parseGraphDefinitionJson` / native load | `tests/ts/adversarial/s4_graph_json_fuzz.test.ts` + Zig | `tests/adversarial/corpus/s4/` |

## Limits

Documented in `src/wasm/abi.zig` and mirrored in `src/ts/graph/limits.ts`.
Enforcement is **pre-allocation**.

## Default gate (strict)

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
bun run mz
```

Default-seed fuzzers + regression corpora run inside `bun test` / `zig build test`.

## Nightly deep run (named optional scope)

Rotating seed + large count across all four surfaces, with worker deadlines:

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
bun tools/testing/adversarial_deep.ts
# or explicit:
bun tools/testing/adversarial_deep.ts --seed=0x4d415448 --count=5000 --deadline-ms=2000
```

Scope id: **`adversarial_deep`** (task-12 scope field / optional suite — not part of the mandatory full gate).

## Hang containment

Pathological cases spawn a child process with an externally enforced deadline
(`tests/ts/adversarial/deadline.ts`). Deadline kill = test failure.
