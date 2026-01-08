# Spec 02 — Graph lowerer (fuse plan)

**Depends on:** 01 (manifest field names for ports/outputs)  
**Unblocks:** 03, 04  
**Scope:** pure transform GraphDefinition → FusePlan (no wasm emit required to land)

## Goal

Turn a validated `GraphDefinition` into a **fuse plan** that:

1. Topo-orders compute nodes  
2. Drops nodes not needed for graph **outputs** (reachability)  
3. Assigns stable input / param / output **value** slots  
4. Describes each compute node body (expr text + port binding) for codegen  

Scalar-first. Matrix/full-value plans allowed as data only if kinds are known; codegen comes in 03/07.

## FusePlan shape (normative sketch)

```ts
type FusePlan = {
  inputs: Array<{ name: string; kind: PortKind; sourceNodeId: string }>;
  params: Array<{ name: string; kind: "number"; nodeId: string; param: string; default: number }>;
  /** Topo order among reachable compute nodes only */
  nodes: Array<{
    id: string;
    expr: string;           // boundary-rewritten or real names — pick one, document
    inputPorts: string[];   // producer slot names or node ids
    paramNames: string[];
    outputKind: PortKind;
  }>;
  outputs: Array<{ name: string; fromNodeId: string; kind: PortKind }>;
};
```

Document the chosen param naming: e.g. `"nodeId.param"` globally unique in the fused entry.

## Todos

- [x] Add `src/ts/graph/fuse.ts` (primary); Zig mirror optional until CLI needs it (spec 05)
- [x] Reuse `normalizeGraphDefinition` + `topoSort`; fail on cycles (already)
- [x] Reachability: mark nodes backward from `outputs`; drop unused `expr`/`const` from plan
- [x] Port binding plan: map edges → producer node outputs feeding consumer inputs
- [x] Collect all params across nodes into flat list with stable order
- [x] Reject fuse v1: `type: "wasm"` without dual `expr`, unsupported kinds (document list)
- [x] Boundary rewrite policy: either keep real names for fuse codegen **or** rewrite to `x,y,z…` like runner — **one policy**, tested
- [x] Unit tests for chain, diamond (shared intermediate), multi-output, unused node drop
- [x] Error messages: stable strings for unsupported node types

### Landed decisions

| Topic | Choice |
|-------|--------|
| Boundary rewrite | **`real_names`** — keep authored port/param names in `expr` (no `x,y,z` rewrite). GraphRunner still rewrites for multi-module AOT only. |
| Param flat names | `"${nodeId}.${param}"`, topo order of reachable expr nodes, then `Object.keys(params)` |
| Port binding | `inputPorts[i]` = producer **node id** for declared input `inputs[i]` |
| Input kinds | `inputKinds[i]` parallel to `inputs` (default `"number"`); all known `PortKind`s allowed as plan **data**; codegen may reject non-scalar later |
| Consts | Reachable const nodes listed in `plan.consts`; unused dropped |
| Input names | Host-facing `plan.inputs[].name` must be unique (`FUSE_ERR.duplicateInputName`) |
| Kind check | Lightweight edge kind check (`kindsCompatible`) on reachable expr consumers |
| Outputs | Empty/omitted `outputs` inherit normalize “all nodes are outputs”; empty node list → `FUSE_ERR.emptyOutputs` |
| v1 reject | Reachable `type: "wasm"` → `FuseError` (`FUSE_ERR.wasmUnsupported`); replace with expr or keep multi-module GraphRunner |

## Do NOTs

- Do **not** instantiate wasm or call the AOT compiler in this module.
- Do **not** change multi-module `GraphRunner` behavior.
- Do **not** silently ignore unreachable graph outputs (error if output ref missing).
- Do **not** lower prebuilt opaque wasm nodes in v1 (hard error with clear message).
- Do **not** invent a second graph JSON schema; input remains existing `GraphDefinition`.

## Tests

| ID | Case | Expected |
|----|------|----------|
| T1 | Linear chain 3 expr, one output | 3 nodes in topo order, 1 output |
| T2 | Diamond: A→B, A→C, outputs B and C | A appears once in `nodes` |
| T3 | Unused expr node | Absent from `nodes` |
| T4 | Multi outputs `{ u: a.out, v: b.out }` | `outputs.length === 2`, names preserved |
| T5 | Two nodes with params `k` | Flattened unique param names |
| T6 | `wasm` node only | Throws / FuseError |
| T7 | Missing edge for required input | Throws |
| T8 | Cycle | Throws (topo) |

Suggested:

```bash
bun test tests/ts/graph/fuse*.ts
# or co-located tests under src/ts/graph/
```

## Expected outcomes

- [x] Deterministic `FusePlan` from any valid scalar multi-module graph fixture  
- [x] Multi-**output values** represented explicitly (not single implied out)  
- [x] Dead-node elimination works  
- [x] Ready as sole input to codegen (spec 03)  

