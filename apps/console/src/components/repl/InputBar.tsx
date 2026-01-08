import { session } from "../../state/session";
import { ExprEditor } from "./ExprEditor";

export function InputBar() {
  return (
    <div class="shrink-0 border-t border-line bg-panel px-3 py-2.5 sm:px-4">
      <div class="flex items-center gap-2">
        <span class="select-none font-mono text-keyword" aria-hidden="true">
          ➜
        </span>
        <ExprEditor />
        <button
          type="button"
          class="ghost-btn shrink-0 px-3 py-2.5 text-[12px]"
          disabled={session.state.status !== "ready" || !session.state.inputDraft.trim()}
          onClick={() => session.submit()}
          title="Run expression (Enter)"
        >
          Run
        </button>
      </div>
      <p id="input-hints" class="mt-1.5 pl-6 text-[11px] text-fg-muted">
        Enter to run · Tab/↑↓ complete · ↑↓ history when closed · Ctrl+L clear
      </p>
    </div>
  );
}
