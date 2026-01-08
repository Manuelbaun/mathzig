/**
 * Node / bun entry for graph fuse compile helpers.
 *
 * Browser code must import from `./index` (or `@mathzig/graph`) only — never
 * this module. Top-level `node:*` imports here are intentional.
 */

export {
  compileFused,
  fusePlanSemanticKey,
  resolveMathzigBin,
} from "./fused_compile";
