import { For, Show, createEffect, createMemo, on } from "solid-js";
import { buildStream, session } from "../../state/session";
import { LogEntryView } from "./LogEntry";
import { PlotHost } from "../plot/PlotHost";

export function OutputStream() {
  let scroller: HTMLDivElement | undefined;

  const stream = createMemo(() => buildStream(session.state.logs, session.state.plots));
  const isEmpty = createMemo(() => stream().length === 0);

  createEffect(
    on(
      () => {
        const items = stream();
        const last = items[items.length - 1];
        return last ? `${last.kind}-${last.seq}` : "empty";
      },
      () => {
        if (scroller) scroller.scrollTop = scroller.scrollHeight;
      },
    ),
  );

  return (
    <div ref={scroller} class="output-scroller min-h-0 flex-1 overflow-y-auto" role="log" aria-live="polite">
      <Show when={isEmpty()}>
        <div class="flex flex-col items-start gap-2 px-4 py-10 text-[13px] text-fg-secondary">
          <p class="font-medium text-fg">Console is clear.</p>
          <p>
            Type an expression below, or try{" "}
            <button
              type="button"
              class="font-mono text-keyword underline-offset-2 hover:underline"
              onClick={() => session.insertSnippet("help")}
            >
              help
            </button>
            ,{" "}
            <button
              type="button"
              class="font-mono text-keyword underline-offset-2 hover:underline"
              onClick={() => session.insertSnippet("sin(pi/4)")}
            >
              sin(pi/4)
            </button>
            , or{" "}
            <button
              type="button"
              class="font-mono text-keyword underline-offset-2 hover:underline"
              onClick={() => session.insertSnippet("sample")}
            >
              sample
            </button>
            .
          </p>
        </div>
      </Show>

      <For each={stream()}>
        {(item) => (
          <Show
            when={item.kind === "log" ? item : false}
            fallback={item.kind === "plot" ? <PlotHost entry={item.plot} /> : null}
          >
            {(logItem) => <LogEntryView entry={logItem().log} />}
          </Show>
        )}
      </For>
    </div>
  );
}
