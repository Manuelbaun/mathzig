import { Editor } from "@tiptap/core";
import Document from "@tiptap/extension-document";
import History from "@tiptap/extension-history";
import Paragraph from "@tiptap/extension-paragraph";
import Placeholder from "@tiptap/extension-placeholder";
import Text from "@tiptap/extension-text";
import { createEffect, on, onCleanup, onMount } from "solid-js";
import { session } from "../../state/session";
import { ExprAutocomplete } from "./expr_autocomplete";

function textToDoc(text: string) {
  return {
    type: "doc",
    content: [
      {
        type: "paragraph",
        content: text ? [{ type: "text", text }] : [],
      },
    ],
  };
}

export function ExprEditor() {
  let host!: HTMLDivElement;
  let editor: Editor | undefined;
  let applyingExternal = false;
  let suggestionActive = false;

  const syncDraftFromEditor = () => {
    if (!editor || applyingExternal) return;
    const text = editor.getText({ blockSeparator: "\n" }).replace(/\n/g, "");
    if (text !== session.state.inputDraft) {
      session.setInputDraft(text);
    }
  };

  const setEditorText = (text: string, focusEnd = false) => {
    if (!editor) return;
    const current = editor.getText({ blockSeparator: "\n" }).replace(/\n/g, "");
    if (current === text) {
      if (focusEnd) editor.commands.focus("end");
      return;
    }
    applyingExternal = true;
    editor.commands.setContent(textToDoc(text), { emitUpdate: false });
    applyingExternal = false;
    if (focusEnd) {
      editor.commands.focus("end");
    }
  };

  onMount(() => {
    editor = new Editor({
      element: host,
      editable: session.state.status === "ready",
      extensions: [
        Document,
        Paragraph,
        Text,
        History,
        Placeholder.configure({
          placeholder: "Try help, sin(pi/4), plot(...), load…",
          emptyEditorClass: "is-editor-empty",
          emptyNodeClass: "is-empty",
        }),
        ExprAutocomplete.configure({
          getVariables: () => session.state.variables,
          onActiveChange: (active) => {
            suggestionActive = active;
          },
        }),
      ],
      content: textToDoc(session.state.inputDraft),
      editorProps: {
        attributes: {
          id: "mz-input",
          class: "mz-expr-prose",
          role: "textbox",
          "aria-multiline": "false",
          "aria-autocomplete": "list",
          "aria-describedby": "input-hints",
          spellcheck: "false",
        },
        transformPastedText: (text) => text.replace(/\s*\n+\s*/g, " ").trim(),
        handleKeyDown: (_view, event) => {
          // Suggestion plugin consumes arrows/enter/tab first when active.
          if (suggestionActive) {
            if (event.key === "ArrowUp" || event.key === "ArrowDown" || event.key === "Enter" || event.key === "Tab") {
              return false; // let suggestion plugin handle
            }
          }

          if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();
            syncDraftFromEditor();
            session.submit();
            return true;
          }

          // Block hard breaks / multi-line
          if (event.key === "Enter" && event.shiftKey) {
            event.preventDefault();
            return true;
          }

          if (!suggestionActive && event.key === "ArrowUp") {
            event.preventDefault();
            session.historyPrev();
            return true;
          }
          if (!suggestionActive && event.key === "ArrowDown") {
            event.preventDefault();
            session.historyNext();
            return true;
          }

          if (event.key === "l" && event.ctrlKey) {
            event.preventDefault();
            session.clearOutput();
            return true;
          }

          return false;
        },
      },
      onUpdate: () => {
        syncDraftFromEditor();
      },
    });
  });

  onCleanup(() => {
    editor?.destroy();
    editor = undefined;
  });

  // External draft changes (history, insertSnippet, submit clear)
  createEffect(
    on(
      () => session.state.inputDraft,
      (draft) => {
        setEditorText(draft, false);
      },
    ),
  );

  createEffect(
    on(
      () => session.state.status,
      (status) => {
        editor?.setEditable(status === "ready");
        if (status === "ready") {
          queueMicrotask(() => editor?.commands.focus("end"));
        }
      },
    ),
  );

  createEffect(
    on(
      () => session.state.focusInputToken,
      () => {
        if (session.state.status === "ready") {
          queueMicrotask(() => {
            setEditorText(session.state.inputDraft, true);
          });
        }
      },
    ),
  );

  return (
    <div class="mz-expr-editor relative min-w-0 flex-1">
      <span class="sr-only" id="mz-input-label">
        Mathematical expression
      </span>
      <div
        ref={host}
        class="mz-expr-host w-full rounded-md border border-line bg-inset px-3 py-2.5 font-mono text-[13px] text-fg focus-within:border-focus"
        classList={{
          "opacity-50 pointer-events-none": session.state.status !== "ready",
        }}
        aria-labelledby="mz-input-label"
      />
    </div>
  );
}
