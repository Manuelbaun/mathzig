import { For, Show, createEffect, createMemo, createSignal, onCleanup } from "solid-js";
import { NODE_KIND_META, type NodeKind } from "../../engine/graph/node_draft";

export type CommandItem = {
  id: string;
  label: string;
  group: string;
  hint?: string;
  /** When true, Enter/click do not run the command. */
  disabled?: boolean;
  /** Shown as hint / title when disabled. */
  disabledReason?: string;
  run: () => void;
};

type Props = {
  open: boolean;
  onClose: () => void;
  commands: CommandItem[];
};

export function GraphCommandMenu(props: Props) {
  const [query, setQuery] = createSignal("");
  const [active, setActive] = createSignal(0);
  let inputRef: HTMLInputElement | undefined;

  const filtered = createMemo(() => {
    const q = query().trim().toLowerCase();
    if (!q) return props.commands;
    return props.commands.filter(
      (c) =>
        c.label.toLowerCase().includes(q) ||
        c.group.toLowerCase().includes(q) ||
        (c.hint?.toLowerCase().includes(q) ?? false),
    );
  });

  createEffect(() => {
    if (props.open) {
      setQuery("");
      setActive(0);
      queueMicrotask(() => inputRef?.focus());
    }
  });

  createEffect(() => {
    // reset active when filter changes
    filtered();
    setActive(0);
  });

  function onKeyDown(e: KeyboardEvent) {
    if (!props.open) return;
    if (e.key === "Escape") {
      e.preventDefault();
      props.onClose();
      return;
    }
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setActive((i) => Math.min(i + 1, Math.max(0, filtered().length - 1)));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActive((i) => Math.max(i - 1, 0));
    } else if (e.key === "Enter") {
      e.preventDefault();
      const item = filtered()[active()];
      if (item && !item.disabled) {
        item.run();
        props.onClose();
      }
    }
  }

  createEffect(() => {
    if (!props.open) return;
    window.addEventListener("keydown", onKeyDown);
    onCleanup(() => window.removeEventListener("keydown", onKeyDown));
  });

  return (
    <Show when={props.open}>
      <div
        class="fixed inset-0 z-50 flex items-start justify-center bg-black/50 pt-[12vh]"
        onClick={props.onClose}
        role="presentation"
      >
        <div
          class="w-full max-w-lg overflow-hidden rounded-lg border border-line bg-panel shadow-xl"
          onClick={(e) => e.stopPropagation()}
          role="dialog"
          aria-label="Command menu"
        >
          <input
            ref={inputRef}
            class="w-full border-b border-line bg-inset px-3 py-2.5 font-mono text-[13px] text-fg outline-none"
            placeholder="Search commands or nodes…"
            value={query()}
            onInput={(e) => setQuery(e.currentTarget.value)}
          />
          <ul class="max-h-80 overflow-y-auto py-1">
            <For
              each={filtered()}
              fallback={
                <li class="px-3 py-2 text-[12px] text-fg-muted">No matches</li>
              }
            >
              {(item, i) => (
                <li>
                  <button
                    type="button"
                    disabled={item.disabled}
                    title={item.disabled ? item.disabledReason ?? item.hint : item.hint}
                    class="flex w-full items-center justify-between gap-2 px-3 py-1.5 text-left text-[12px] disabled:cursor-not-allowed disabled:opacity-40"
                    classList={{
                      "bg-keyword/20 text-fg": i() === active() && !item.disabled,
                      "text-fg-secondary hover:bg-inset": i() !== active() && !item.disabled,
                      "text-fg-muted": !!item.disabled,
                    }}
                    onMouseEnter={() => setActive(i())}
                    onClick={() => {
                      if (item.disabled) return;
                      item.run();
                      props.onClose();
                    }}
                  >
                    <span>
                      <span class="text-fg-muted">{item.group} · </span>
                      {item.label}
                    </span>
                    <Show when={item.disabled ? item.disabledReason ?? item.hint : item.hint}>
                      {(h) => (
                        <span class="max-w-[45%] truncate font-mono text-[10px] text-fg-muted" title={h()}>
                          {h()}
                        </span>
                      )}
                    </Show>
                  </button>
                </li>
              )}
            </For>
          </ul>
        </div>
      </div>
    </Show>
  );
}

/** Build "Add …" commands from palette meta. */
export function addNodeCommands(onAdd: (kind: NodeKind) => void): CommandItem[] {
  return NODE_KIND_META.map((m) => ({
    id: `add:${m.kind}`,
    label: `Add ${m.label}`,
    group: m.group,
    hint: m.title,
    run: () => onAdd(m.kind),
  }));
}
