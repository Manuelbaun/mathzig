import { For, Match, Show, Switch } from "solid-js";
import type { FlowNode, MzNodeData, NodeManifest, PortKind } from "../../engine/graph/editor_types";
import { PORT_KINDS } from "../../engine/graph/editor_types";
import {
  addExprInput,
  addWasmInput,
  patchWasmInput,
  removeExprInput,
  removeWasmInput,
  renameExprInput,
  setExprInputKind,
} from "../../engine/graph/port_edit";
import { readNodeManifest } from "@mathzig/graph";

type Props = {
  node: FlowNode | null;
  onChange: (nodeId: string, patch: MzNodeData) => void;
};

const TYPE_LABEL: Record<string, string> = {
  input: "Input",
  const: "Constant",
  expr: "Expression",
  wasm: "WASM module",
  output: "Output",
};

export function GraphInspector(props: Props) {
  return (
    <div class="px-3 py-2">
      <h2 class="mb-1.5 text-[10px] font-semibold tracking-wider text-fg-muted uppercase">
        Inspector
      </h2>
      <Show
        when={props.node}
        fallback={<p class="text-[12px] text-fg-muted">Select a node on the canvas.</p>}
      >
        {(n) => <InspectorBody node={n()} onChange={props.onChange} />}
      </Show>
    </div>
  );
}

function InspectorBody(props: {
  node: FlowNode;
  onChange: (nodeId: string, patch: MzNodeData) => void;
}) {
  const id = () => props.node.id;
  const data = () => props.node.data;

  return (
    <div class="space-y-2 font-mono text-[11px]">
      <div class="text-fg-muted">
        <span class="text-fg-secondary">{id()}</span>
        {" · "}
        {TYPE_LABEL[data().mzType] ?? data().mzType}
      </div>

      <Switch>
        <Match when={data().mzType === "input" ? data() : null}>
          {(d) => {
            const input = () => d() as Extract<MzNodeData, { mzType: "input" }>;
            return (
              <>
                <label class="block">
                  <span class="text-fg-muted">Name</span>
                  <input
                    class="mt-0.5 w-full rounded border border-line bg-inset px-2 py-1 text-fg"
                    value={input().name}
                    onInput={(e) =>
                      props.onChange(id(), { ...input(), name: e.currentTarget.value })
                    }
                  />
                </label>
                <KindSelect
                  label="Value type"
                  value={input().kind}
                  onChange={(kind) => props.onChange(id(), { ...input(), kind })}
                />
              </>
            );
          }}
        </Match>

        <Match when={data().mzType === "const" ? data() : null}>
          {(d) => {
            const c = () => d() as Extract<MzNodeData, { mzType: "const" }>;
            const valueText = () => {
              const v = c().value;
              if (typeof v === "string") return JSON.stringify(v);
              if (typeof v === "number" || typeof v === "boolean") return String(v);
              return JSON.stringify(v);
            };
            return (
              <>
                <label class="block">
                  <span class="text-fg-muted">Value (JSON)</span>
                  <input
                    class="mt-0.5 w-full rounded border border-line bg-inset px-2 py-1 text-fg"
                    value={valueText()}
                    onInput={(e) => {
                      const raw = e.currentTarget.value.trim();
                      let value: unknown = raw;
                      try {
                        value = JSON.parse(raw);
                      } catch {
                        const n = Number(raw);
                        value = Number.isFinite(n) && raw !== "" ? n : raw;
                      }
                      props.onChange(id(), { ...c(), value: value as never });
                    }}
                  />
                </label>
                <KindSelect
                  label="Value type"
                  value={c().kind}
                  onChange={(kind) => props.onChange(id(), { ...c(), kind })}
                />
              </>
            );
          }}
        </Match>

        <Match when={data().mzType === "expr" ? data() : null}>
          {(d) => {
            const ex = () => d() as Extract<MzNodeData, { mzType: "expr" }>;
            return (
              <>
                <label class="block">
                  <span class="text-fg-muted">Expression</span>
                  <textarea
                    class="mt-0.5 min-h-[64px] w-full rounded border border-line bg-inset px-2 py-1 text-fg"
                    value={ex().expr}
                    onInput={(e) =>
                      props.onChange(id(), { ...ex(), expr: e.currentTarget.value })
                    }
                  />
                </label>
                <p class="text-[10px] leading-snug text-fg-muted">
                  Compiled into its own WASM module when you compile the graph.
                </p>

                <div class="space-y-1.5">
                  <div class="flex items-center justify-between gap-2">
                    <span class="text-fg-muted">Input ports</span>
                    <button
                      type="button"
                      class="ghost-btn !py-0.5 !px-2"
                      onClick={() => props.onChange(id(), addExprInput(ex()))}
                    >
                      + Add input
                    </button>
                  </div>
                  <Show
                    when={ex().inputs.length > 0}
                    fallback={
                      <p class="text-[11px] text-fg-muted">
                        No inputs — click <strong class="text-fg-secondary">+ Add input</strong>.
                      </p>
                    }
                  >
                    <For each={ex().inputs}>
                      {(name, i) => (
                        <div class="flex flex-wrap items-center gap-1 rounded border border-line bg-inset px-1.5 py-1">
                          <input
                            class="min-w-0 flex-1 rounded border border-line bg-panel px-1.5 py-0.5 text-fg"
                            value={name}
                            title="Port name (used in edges and as expression binding)"
                            aria-label={`Input port name ${name}`}
                            onChange={(e) => {
                              const next = e.currentTarget.value.trim() || name;
                              props.onChange(id(), renameExprInput(ex(), i(), next));
                            }}
                          />
                          <select
                            class="rounded border border-line bg-panel px-1 py-0.5 text-fg"
                            value={ex().inputKinds[i()] ?? "number"}
                            aria-label={`Value type for port ${name}`}
                            onChange={(e) =>
                              props.onChange(
                                id(),
                                setExprInputKind(ex(), i(), e.currentTarget.value as PortKind),
                              )
                            }
                          >
                            <For each={PORT_KINDS}>{(k) => <option value={k}>{k}</option>}</For>
                          </select>
                          <button
                            type="button"
                            class="ghost-btn !px-1.5 !py-0.5 text-err"
                            title={`Remove input port ${name}`}
                            aria-label={`Remove input port ${name}`}
                            onClick={() => props.onChange(id(), removeExprInput(ex(), i()))}
                          >
                            ×
                          </button>
                        </div>
                      )}
                    </For>
                  </Show>
                </div>

                <div class="space-y-1.5">
                  <div class="flex items-center justify-between gap-2">
                    <span class="text-fg-muted">Parameters</span>
                    <button
                      type="button"
                      class="ghost-btn !py-0.5 !px-2"
                      onClick={() => {
                        const params = { ...ex().params };
                        let name = "a";
                        let i = 0;
                        while (name in params || ex().inputs.includes(name)) {
                          i++;
                          name = `p${i}`;
                        }
                        params[name] = 0;
                        props.onChange(id(), { ...ex(), params });
                      }}
                    >
                      + Add parameter
                    </button>
                  </div>
                  <p class="text-[10px] text-fg-muted">
                    Tunable after compile without recompiling (not input ports).
                  </p>
                  <Show
                    when={Object.keys(ex().params).length > 0}
                    fallback={<p class="text-[11px] text-fg-muted">No parameters.</p>}
                  >
                    <For each={Object.entries(ex().params)}>
                      {([name, value]) => (
                        <div class="flex flex-wrap items-center gap-1 rounded border border-line bg-inset px-1.5 py-1">
                          <input
                            class="min-w-0 flex-1 rounded border border-line bg-panel px-1.5 py-0.5 text-fg"
                            value={name}
                            aria-label={`Parameter name ${name}`}
                            onChange={(e) => {
                              const nextName = e.currentTarget.value.trim() || name;
                              const params = { ...ex().params };
                              const v = params[name]!;
                              delete params[name];
                              params[nextName] = v;
                              props.onChange(id(), { ...ex(), params });
                            }}
                          />
                          <input
                            type="number"
                            class="w-20 rounded border border-line bg-panel px-1.5 py-0.5 text-fg"
                            value={value}
                            step="any"
                            aria-label={`Value for parameter ${name}`}
                            onInput={(e) => {
                              const num = Number(e.currentTarget.value);
                              if (!Number.isFinite(num)) return;
                              props.onChange(id(), {
                                ...ex(),
                                params: { ...ex().params, [name]: num },
                              });
                            }}
                          />
                          <button
                            type="button"
                            class="ghost-btn !px-1.5 !py-0.5 text-err"
                            aria-label={`Remove parameter ${name}`}
                            onClick={() => {
                              const params = { ...ex().params };
                              delete params[name];
                              props.onChange(id(), { ...ex(), params });
                            }}
                          >
                            ×
                          </button>
                        </div>
                      )}
                    </For>
                  </Show>
                </div>
                <KindSelect
                  label="Output value type"
                  value={ex().outputKind}
                  onChange={(kind) => props.onChange(id(), { ...ex(), outputKind: kind })}
                />
              </>
            );
          }}
        </Match>

        <Match when={data().mzType === "wasm" ? data() : null}>
          {(d) => {
            const w = () => d() as Extract<MzNodeData, { mzType: "wasm" }>;
            const inputs = () => w().manifest?.inputs ?? [];
            return (
              <>
                <div class="space-y-1.5">
                  <span class="text-fg-muted">External WASM module</span>
                  <p class="text-[10px] leading-snug text-fg-muted">
                    Choose a MathZig-compatible .wasm file. Its node metadata defines inputs,
                    parameters, and output.
                  </p>
                  <input
                    type="file"
                    accept=".wasm,application/wasm"
                    class="block w-full text-[11px] text-fg-secondary file:mr-2 file:rounded file:border file:border-line file:bg-inset file:px-2 file:py-1 file:text-fg"
                    onChange={(e) => {
                      const file = e.currentTarget.files?.[0];
                      if (!file) return;
                      void importWasmFile(file, id(), w(), props.onChange);
                    }}
                  />
                  <Show when={w().wasmRef}>
                    <p class="truncate text-[10px] text-fg-muted" title={w().wasmRef}>
                      {w().wasmRef.startsWith("data:")
                        ? "Loaded from file (data URL)"
                        : w().wasmRef}
                    </p>
                  </Show>
                  <Show when={!w().manifest}>
                    <p class="text-[11px] text-warn">
                      This module does not expose MathZig graph metadata. Compile it with{" "}
                      <code class="text-fg-secondary">mathzig compile --node</code>, or provide a
                      compatible manifest below.
                    </p>
                  </Show>
                </div>

                <div class="space-y-1.5">
                  <div class="flex items-center justify-between gap-2">
                    <span class="text-fg-muted">Input ports</span>
                    <button
                      type="button"
                      class="ghost-btn !py-0.5 !px-2"
                      onClick={() => props.onChange(id(), addWasmInput(w()))}
                    >
                      + Add input
                    </button>
                  </div>
                  <For each={inputs()}>
                    {(p, i) => (
                      <div class="flex flex-wrap items-center gap-1 rounded border border-line bg-inset px-1.5 py-1">
                        <input
                          class="min-w-0 flex-1 rounded border border-line bg-panel px-1.5 py-0.5 text-fg"
                          value={p.name}
                          aria-label={`WASM input port ${p.name}`}
                          onChange={(e) => {
                            const next = e.currentTarget.value.trim() || p.name;
                            props.onChange(id(), patchWasmInput(w(), i(), { name: next }));
                          }}
                        />
                        <select
                          class="rounded border border-line bg-panel px-1 py-0.5 text-fg"
                          value={p.kind}
                          aria-label={`Value type for ${p.name}`}
                          onChange={(e) =>
                            props.onChange(
                              id(),
                              patchWasmInput(w(), i(), {
                                kind: e.currentTarget.value as PortKind,
                              }),
                            )
                          }
                        >
                          <For each={PORT_KINDS}>{(k) => <option value={k}>{k}</option>}</For>
                        </select>
                        <button
                          type="button"
                          class="ghost-btn !px-1.5 !py-0.5 text-err"
                          aria-label={`Remove input port ${p.name}`}
                          onClick={() => props.onChange(id(), removeWasmInput(w(), i()))}
                        >
                          ×
                        </button>
                      </div>
                    )}
                  </For>
                </div>

                <label class="block">
                  <span class="text-fg-muted">Manifest JSON (advanced)</span>
                  <textarea
                    class="mt-0.5 min-h-[64px] w-full rounded border border-line bg-inset px-2 py-1 text-fg"
                    value={w().manifest ? JSON.stringify(w().manifest, null, 2) : ""}
                    onChange={(e) => {
                      try {
                        const manifest = JSON.parse(e.currentTarget.value);
                        props.onChange(id(), { ...w(), manifest });
                      } catch {
                        /* ignore incomplete JSON */
                      }
                    }}
                  />
                </label>
              </>
            );
          }}
        </Match>

        <Match when={data().mzType === "output" ? data() : null}>
          {(d) => {
            const o = () => d() as Extract<MzNodeData, { mzType: "output" }>;
            return (
              <label class="block">
                <span class="text-fg-muted">Output name</span>
                <input
                  class="mt-0.5 w-full rounded border border-line bg-inset px-2 py-1 text-fg"
                  value={o().name}
                  onInput={(e) => props.onChange(id(), { ...o(), name: e.currentTarget.value })}
                />
              </label>
            );
          }}
        </Match>
      </Switch>
    </div>
  );
}

async function importWasmFile(
  file: File,
  nodeId: string,
  current: Extract<MzNodeData, { mzType: "wasm" }>,
  onChange: (nodeId: string, patch: MzNodeData) => void,
) {
  const buf = await file.arrayBuffer();
  const bytes = new Uint8Array(buf);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]!);
  const dataUrl = `data:application/wasm;base64,${btoa(binary)}`;

  let manifest: NodeManifest | null = current.manifest;
  try {
    const module = await WebAssembly.compile(bytes);
    const fromModule = readNodeManifest(module) as NodeManifest | null;
    if (fromModule) manifest = fromModule;
  } catch {
    // Keep existing manifest; compile-time will report invalid wasm.
  }

  onChange(nodeId, {
    ...current,
    wasmRef: dataUrl,
    manifest,
  });
}

function KindSelect(props: {
  value: PortKind;
  onChange: (k: PortKind) => void;
  label?: string;
}) {
  return (
    <label class="block">
      <span class="text-fg-muted">{props.label ?? "Value type"}</span>
      <select
        class="mt-0.5 w-full rounded border border-line bg-inset px-2 py-1 text-fg"
        value={props.value}
        onChange={(e) => props.onChange(e.currentTarget.value as PortKind)}
      >
        <For each={PORT_KINDS}>{(k) => <option value={k}>{k}</option>}</For>
      </select>
    </label>
  );
}
