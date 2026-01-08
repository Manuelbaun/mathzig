import { createEffect, createSignal, onCleanup, Show } from "solid-js";
import katex from "katex";
import type { LogEntry as LogEntryT } from "../../state/session";
import { session } from "../../state/session";

function formatTime(ts: number) {
  const d = new Date(ts);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

/** True when this entry is eligible for a KaTeX attempt. */
function wantsLatex(e: LogEntryT): boolean {
  return Boolean(
    e.renderLatex && e.latex && e.kind === "result" && !e.latex.includes("unsupported:"),
  );
}

/**
 * Render LaTeX into `el`. On failure, clear the node and log to the browser console
 * so the UI never shows KaTeX's red error text.
 */
function renderLatexSafe(latex: string, el: HTMLElement, expr: string): boolean {
  el.innerHTML = "";
  try {
    katex.render(latex, el, {
      throwOnError: true,
      displayMode: false,
      strict: "ignore",
      trust: false,
    });
    // Extra guard: some KaTeX builds still leave error markup
    if (el.querySelector(".katex-error")) {
      const msg = el.querySelector(".katex-error")?.textContent ?? "katex-error";
      el.innerHTML = "";
      console.warn("[MathZig] LaTeX not renderable", { expr, latex, reason: msg });
      return false;
    }
    return true;
  } catch (err) {
    el.innerHTML = "";
    console.warn("[MathZig] LaTeX not renderable", { expr, latex, err });
    return false;
  }
}

export function LogEntryView(props: { entry: LogEntryT }) {
  let latexEl: HTMLDivElement | undefined;
  const [latexOk, setLatexOk] = createSignal(false);

  createEffect(() => {
    const e = props.entry;
    if (!latexEl) {
      setLatexOk(false);
      return;
    }
    latexEl.innerHTML = "";

    if (!wantsLatex(e)) {
      if (e.renderLatex && e.latex?.includes("unsupported:")) {
        console.warn("[MathZig] LaTeX skipped (engine unsupported node)", {
          expr: e.expr,
          latex: e.latex,
        });
      }
      setLatexOk(false);
      return;
    }

    const ok = renderLatexSafe(e.latex!, latexEl, e.expr);
    setLatexOk(ok);
  });

  onCleanup(() => {
    if (latexEl) latexEl.innerHTML = "";
  });

  const resultClass = () => {
    switch (props.entry.kind) {
      case "error":
        return "text-err";
      case "success":
        return "text-ok";
      case "info":
      case "help":
        return "text-fg-secondary whitespace-pre-wrap";
      default:
        return "text-number font-mono";
    }
  };

  return (
    <article class="border-b border-line/50 px-3 py-2.5 sm:px-4">
      <Show when={props.entry.expr}>
        <div class="mb-1 flex items-baseline gap-2 font-mono text-[12px]">
          <span class="text-keyword select-none">➜</span>
          <button
            type="button"
            class="min-w-0 flex-1 break-all text-left text-fg hover:text-keyword"
            title="Insert into input (double-click to re-run)"
            onClick={() => session.insertSnippet(props.entry.expr)}
            onDblClick={() => session.rerunExpr(props.entry.expr)}
          >
            {props.entry.expr}
          </button>
          <span class="ml-auto shrink-0 text-[11px] text-fg-muted tabular-nums">
            {formatTime(props.entry.timestamp)}
          </span>
        </div>
      </Show>
      <div class="flex items-start justify-between gap-4">
        <div class={`min-w-0 flex-1 text-[13px] leading-relaxed ${resultClass()}`}>
          {props.entry.result}
        </div>
        <div
          ref={latexEl}
          class="max-w-[55%] shrink-0 overflow-x-auto text-right text-[13px] leading-relaxed text-fg-secondary"
          classList={{ hidden: !latexOk() }}
          aria-hidden={!latexOk()}
        />
      </div>
    </article>
  );
}
