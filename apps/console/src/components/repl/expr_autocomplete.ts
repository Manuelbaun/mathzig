import { Extension } from "@tiptap/core";
import { PluginKey } from "@tiptap/pm/state";
import Suggestion, { type SuggestionOptions, type Trigger } from "@tiptap/suggestion";
import { buildSuggestItems, type SuggestItem } from "../../lib/autocomplete_catalog";
import type { VarEntry } from "../../engine/value_tags";
import { createSuggestionRenderer } from "./suggestion_popup";

export const ExprAutocompletePluginKey = new PluginKey("exprAutocomplete");

/** Match a trailing identifier / dotted name before the cursor (no trigger char). */
export function findIdentifierSuggestionMatch({ $position }: Trigger) {
  const textBefore = $position.parent.textBetween(0, $position.parentOffset, undefined, "\ufffc");

  // Identifier: starts with letter/underscore, then word chars, or dotted path (demo_data, m)
  const match = /([A-Za-z_][\w$]*(?:\.[A-Za-z_][\w$]*)*)$/.exec(textBefore);
  if (!match) return null;

  const query = match[1]!;
  if (!query) return null;

  const from = $position.pos - query.length;
  const to = $position.pos;

  return {
    range: { from, to },
    query,
    text: query,
  };
}

export type ExprAutocompleteOptions = {
  suggestion: Partial<SuggestionOptions<SuggestItem>>;
  getVariables: () => Record<string, VarEntry>;
  /** Called when popup opens/closes so Enter/arrows can prefer suggestion vs history. */
  onActiveChange?: (active: boolean) => void;
};

export const ExprAutocomplete = Extension.create<ExprAutocompleteOptions>({
  name: "exprAutocomplete",

  addOptions() {
    return {
      getVariables: () => ({}),
      onActiveChange: undefined,
      suggestion: {},
    };
  },

  addProseMirrorPlugins() {
    const getVariables = this.options.getVariables;
    const onActiveChange = this.options.onActiveChange;

    return [
      Suggestion<SuggestItem>({
        editor: this.editor,
        ...this.options.suggestion,
        char: "\0",
        pluginKey: ExprAutocompletePluginKey,
        allowSpaces: false,
        startOfLine: false,
        allowedPrefixes: null,
        minQueryLength: 1,
        decorationClass: "mz-suggest-query",
        findSuggestionMatch: findIdentifierSuggestionMatch,
        items: ({ query }) => buildSuggestItems(query, getVariables()),
        command: ({ editor, range, props }) => {
          editor.chain().focus().insertContentAt(range, props.insert).run();
        },
        render: () => {
          const base = createSuggestionRenderer();
          return {
            onStart: (props) => {
              onActiveChange?.(true);
              base.onStart(props);
            },
            onUpdate: (props) => {
              onActiveChange?.(true);
              base.onUpdate(props);
            },
            onKeyDown: (props) => base.onKeyDown(props),
            onExit: () => {
              onActiveChange?.(false);
              base.onExit();
            },
          };
        },
      }),
    ];
  },
});
