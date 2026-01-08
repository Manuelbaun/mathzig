import { For, Show } from "solid-js";
import { Handle, Position, type NodeProps } from "@dschz/solid-flow";
import type {
  MzConstData,
  MzExprData,
  MzInputData,
  MzOutputData,
  MzWasmData,
  PortKind,
} from "../../../engine/graph/editor_types";
import { kindsCompatible } from "../../../engine/graph/editor_adapter";
import { useGraphIssues } from "../GraphIssuesContext";

function kindClass(kind: PortKind | string | undefined, extra?: string) {
  return `mz-handle kind-${kind ?? "number"}${extra ? ` ${extra}` : ""}`;
}

/**
 * Port geometry is fixed-pixel so handles, labels, and measured bounds
 * always agree: header is HEADER_H tall, then one ROW_H row per port.
 * Handles must be direct children of the node box (Solid Flow measures
 * them against it), so they are absolutely positioned at the row centers.
 */
const HEADER_H = 22;
const ROW_H = 18;

function handleTopPx(index: number): string {
  return `${HEADER_H + ROW_H * index + ROW_H / 2}px`;
}

function humanKind(kind: string | undefined): string {
  if (!kind || kind === "number") return "number";
  return kind;
}

type PortRow = {
  in?: { name: string; kind: string };
  out?: { name: string; kind: string };
};

/** In-flow rows reserving vertical space for each port. */
function PortRows(props: { rows: PortRow[] }) {
  return (
    <div class="mz-ports">
      <For each={props.rows}>
        {(row) => (
          <div class="mz-port-row">
            <span class="mz-port-name">
              <Show when={row.in}>
                {(p) => (
                  <>
                    {p().name}
                    <span class="mz-port-kind"> · {humanKind(p().kind)}</span>
                  </>
                )}
              </Show>
            </span>
            <span class="mz-port-name mz-port-out">
              <Show when={row.out}>
                {(p) => (
                  <>
                    {p().name}
                    <span class="mz-port-kind"> · {humanKind(p().kind)}</span>
                  </>
                )}
              </Show>
            </span>
          </div>
        )}
      </For>
    </div>
  );
}

function NodeShell(props: {
  selected?: boolean;
  typeClass: string;
  typeLabel: string;
  id: string;
  ariaLabel: string;
  children: import("solid-js").JSX.Element;
}) {
  const issues = useGraphIssues();
  const nodeIssues = () => issues?.issuesFor(props.id) ?? [];
  const hasError = () => nodeIssues().some((i) => i.severity === "error");
  const hasWarn = () => nodeIssues().some((i) => i.severity === "warning");
  const firstMsg = () => nodeIssues()[0]?.message;

  return (
    <div
      class={`mz-node ${props.typeClass}`}
      classList={{
        selected: props.selected,
        "mz-node-error": hasError(),
        "mz-node-warn": !hasError() && hasWarn(),
      }}
      role="group"
      aria-label={props.ariaLabel}
      title={firstMsg()}
    >
      <div class="mz-node-header">
        <span>{props.typeLabel}</span>
        <span class="normal-case tracking-normal text-fg-secondary">{props.id}</span>
      </div>
      {props.children}
      <Show when={hasError() || hasWarn()}>
        <div
          class="mz-node-issue"
          classList={{ "text-err": hasError(), "text-warn": !hasError() && hasWarn() }}
        >
          {firstMsg()}
        </div>
      </Show>
    </div>
  );
}

function portStateClass(
  nodeId: string,
  port: string,
  portKind: string | undefined,
  role: "source" | "target",
): string {
  const issues = useGraphIssues();
  const missing = issues?.missingPorts(nodeId).has(port) ?? false;
  const fromKind = issues?.connectFromKind() ?? null;
  let extra = "";
  if (missing && role === "target") extra += " mz-handle-required";
  if (fromKind && role === "target") {
    extra += kindsCompatible(fromKind, portKind ?? "number")
      ? " mz-handle-compatible"
      : " mz-handle-incompatible";
  } else if (fromKind && role === "source") {
    extra += " mz-handle-dim";
  }
  return extra;
}

export function MzInputNode(props: NodeProps<MzInputData, "mzInput">) {
  const kind = () => humanKind(props.data.kind);
  return (
    <NodeShell
      selected={props.selected}
      typeClass="mz-node-type-input"
      typeLabel="Input"
      id={props.id}
      ariaLabel={`Input node ${props.id}, ${props.data.name}, ${kind()}`}
    >
      <PortRows rows={[{ out: { name: "out", kind: props.data.kind } }]} />
      <div class="mz-node-body">{props.data.name}</div>
      <Handle
        type="source"
        position={Position.Right}
        id="out"
        isConnectable
        class={kindClass(props.data.kind, portStateClass(props.id, "out", props.data.kind, "source"))}
        style={{ top: handleTopPx(0) }}
        aria-label={`${props.id}, output, ${kind()}`}
        title={`${props.id} output (${kind()})`}
      />
    </NodeShell>
  );
}

export function MzConstNode(props: NodeProps<MzConstData, "mzConst">) {
  const kind = () => humanKind(props.data.kind);
  const valueText = () => {
    const v = props.data.value;
    if (typeof v === "number" || typeof v === "boolean" || typeof v === "string") return String(v);
    return JSON.stringify(v);
  };
  return (
    <NodeShell
      selected={props.selected}
      typeClass="mz-node-type-const"
      typeLabel="Constant"
      id={props.id}
      ariaLabel={`Constant node ${props.id}, ${kind()}`}
    >
      <PortRows rows={[{ out: { name: "out", kind: props.data.kind } }]} />
      <div class="mz-node-body">
        <span class="max-w-[160px] truncate">{valueText()}</span>
      </div>
      <Handle
        type="source"
        position={Position.Right}
        id="out"
        isConnectable
        class={kindClass(props.data.kind, portStateClass(props.id, "out", props.data.kind, "source"))}
        style={{ top: handleTopPx(0) }}
        aria-label={`${props.id}, output, ${kind()}`}
        title={`${props.id} output (${kind()})`}
      />
    </NodeShell>
  );
}

export function MzExprNode(props: NodeProps<MzExprData, "mzExpr">) {
  const inputs = () => props.data.inputs ?? [];
  const kinds = () => props.data.inputKinds ?? [];
  const outKind = () => humanKind(props.data.outputKind);
  const rows = (): PortRow[] => {
    const count = Math.max(inputs().length, 1);
    return Array.from({ length: count }, (_, i) => ({
      in: inputs()[i] != null ? { name: inputs()[i]!, kind: kinds()[i] ?? "number" } : undefined,
      out: i === 0 ? { name: "out", kind: props.data.outputKind } : undefined,
    }));
  };

  return (
    <NodeShell
      selected={props.selected}
      typeClass="mz-node-type-expr"
      typeLabel="Expression"
      id={props.id}
      ariaLabel={`Expression node ${props.id}`}
    >
      <PortRows rows={rows()} />
      <div class="mz-node-body">
        <div class="max-w-[180px] truncate" title={props.data.expr}>
          {props.data.expr}
        </div>
        <Show when={Object.keys(props.data.params ?? {}).length > 0}>
          <div class="text-fg-muted">
            params:{" "}
            {Object.entries(props.data.params)
              .map(([k, v]) => `${k}=${v}`)
              .join(", ")}
          </div>
        </Show>
      </div>

      <For each={inputs()}>
        {(name, i) => (
          <Handle
            type="target"
            position={Position.Left}
            id={name}
            isConnectable
            class={kindClass(
              kinds()[i()] ?? "number",
              portStateClass(props.id, name, kinds()[i()] ?? "number", "target"),
            )}
            style={{ top: handleTopPx(i()) }}
            aria-label={`${props.id}, input ${name}, ${humanKind(kinds()[i()])}`}
            title={`${props.id} input ${name} (${humanKind(kinds()[i()])})`}
          />
        )}
      </For>
      <Handle
        type="source"
        position={Position.Right}
        id="out"
        isConnectable
        class={kindClass(
          props.data.outputKind,
          portStateClass(props.id, "out", props.data.outputKind, "source"),
        )}
        style={{ top: handleTopPx(0) }}
        aria-label={`${props.id}, output, ${outKind()}`}
        title={`${props.id} output (${outKind()})`}
      />
    </NodeShell>
  );
}

export function MzWasmNode(props: NodeProps<MzWasmData, "mzWasm">) {
  const inputs = () => props.data.manifest?.inputs ?? [];
  const outKind = () => humanKind(props.data.manifest?.output?.kind);
  const refShort = () => {
    const r = props.data.wasmRef;
    if (!r) return "no module";
    if (r.startsWith("data:")) return "imported .wasm";
    return r.length > 28 ? r.slice(0, 28) + "…" : r;
  };
  const rows = (): PortRow[] => {
    const count = Math.max(inputs().length, 1);
    return Array.from({ length: count }, (_, i) => ({
      in: inputs()[i] ? { name: inputs()[i]!.name, kind: inputs()[i]!.kind } : undefined,
      out: i === 0 ? { name: "out", kind: props.data.manifest?.output?.kind ?? "number" } : undefined,
    }));
  };

  return (
    <NodeShell
      selected={props.selected}
      typeClass="mz-node-type-wasm"
      typeLabel="WASM"
      id={props.id}
      ariaLabel={`WASM module node ${props.id}`}
    >
      <PortRows rows={rows()} />
      <div class="mz-node-body">
        <div class="max-w-[180px] truncate" title={props.data.wasmRef || "No module imported"}>
          {refShort()}
        </div>
        <Show when={!props.data.manifest}>
          <div class="text-warn" title="Compile with mathzig compile --node, or provide a manifest">
            no metadata
          </div>
        </Show>
      </div>

      <For each={inputs()}>
        {(p, i) => (
          <Handle
            type="target"
            position={Position.Left}
            id={p.name}
            isConnectable
            class={kindClass(
              p.kind,
              portStateClass(props.id, p.name, p.kind, "target"),
            )}
            style={{ top: handleTopPx(i()) }}
            aria-label={`${props.id}, input ${p.name}, ${humanKind(p.kind)}`}
            title={`${props.id} input ${p.name} (${humanKind(p.kind)})`}
          />
        )}
      </For>
      <Handle
        type="source"
        position={Position.Right}
        id="out"
        isConnectable
        class={kindClass(
          props.data.manifest?.output?.kind,
          portStateClass(props.id, "out", props.data.manifest?.output?.kind, "source"),
        )}
        style={{ top: handleTopPx(0) }}
        aria-label={`${props.id}, output, ${outKind()}`}
        title={`${props.id} output (${outKind()})`}
      />
    </NodeShell>
  );
}

export function MzOutputNode(props: NodeProps<MzOutputData, "mzOutput">) {
  return (
    <NodeShell
      selected={props.selected}
      typeClass="mz-node-type-output"
      typeLabel="Output"
      id={props.id}
      ariaLabel={`Output node ${props.id}, ${props.data.name}`}
    >
      <PortRows rows={[{ in: { name: "in", kind: "any" } }]} />
      <div class="mz-node-body">{props.data.name}</div>
      <Handle
        type="target"
        position={Position.Left}
        id="in"
        isConnectable
        class={kindClass("any", portStateClass(props.id, "in", "any", "target"))}
        style={{ top: handleTopPx(0) }}
        aria-label={`${props.id}, input, any type`}
        title={`${props.id} input`}
      />
    </NodeShell>
  );
}

export const mzNodeTypes = {
  mzInput: MzInputNode,
  mzConst: MzConstNode,
  mzExpr: MzExprNode,
  mzWasm: MzWasmNode,
  mzOutput: MzOutputNode,
};
