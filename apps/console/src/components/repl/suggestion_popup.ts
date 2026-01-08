import type { SuggestionKeyDownProps, SuggestionProps } from "@tiptap/suggestion";
import type { SuggestItem } from "../../lib/autocomplete_catalog";
import { kindLabel } from "../../lib/autocomplete_catalog";

export type SuggestionRenderer = {
  onStart: (props: SuggestionProps<SuggestItem>) => void;
  onUpdate: (props: SuggestionProps<SuggestItem>) => void;
  onKeyDown: (props: SuggestionKeyDownProps) => boolean;
  onExit: () => void;
};

/**
 * Vanilla DOM list for TipTap Suggestion (framework-agnostic; works with Solid).
 */
export function createSuggestionRenderer(): SuggestionRenderer {
  let root: HTMLDivElement | null = null;
  let list: HTMLUListElement | null = null;
  let unmount: (() => void) | null = null;
  let selected = 0;
  let latest: SuggestionProps<SuggestItem> | null = null;

  const select = (index: number) => {
    if (!latest || !list) return;
    const max = latest.items.length;
    if (max === 0) return;
    selected = ((index % max) + max) % max;
    const rows = list.querySelectorAll<HTMLElement>("[data-suggest-index]");
    rows.forEach((el, i) => {
      el.classList.toggle("is-active", i === selected);
      if (i === selected) el.scrollIntoView({ block: "nearest" });
    });
  };

  const paint = (props: SuggestionProps<SuggestItem>) => {
    latest = props;
    if (!list) return;
    list.innerHTML = "";

    if (props.items.length === 0) {
      const empty = document.createElement("li");
      empty.className = "mz-suggest-empty";
      empty.textContent = "No matches";
      list.appendChild(empty);
      return;
    }

    if (selected >= props.items.length) selected = 0;

    props.items.forEach((item, i) => {
      const li = document.createElement("li");
      li.role = "option";
      li.dataset.suggestIndex = String(i);
      li.className = "mz-suggest-item" + (i === selected ? " is-active" : "");
      li.id = `mz-suggest-${i}`;

      const main = document.createElement("div");
      main.className = "mz-suggest-main";

      const label = document.createElement("span");
      label.className = "mz-suggest-label";
      label.textContent = item.label;

      const detail = document.createElement("span");
      detail.className = "mz-suggest-detail";
      detail.textContent = item.detail;

      main.append(label, detail);

      const badge = document.createElement("span");
      badge.className = `mz-suggest-kind kind-${item.kind}`;
      badge.textContent = kindLabel(item.kind);

      li.append(main, badge);

      li.addEventListener("mousedown", (e) => {
        e.preventDefault();
        props.command(item);
      });
      li.addEventListener("mouseenter", () => select(i));

      list!.appendChild(li);
    });
  };

  return {
    onStart(props) {
      selected = 0;
      root = document.createElement("div");
      root.className = "mz-suggest-popup";
      root.role = "listbox";
      root.setAttribute("aria-label", "Expression completions");

      list = document.createElement("ul");
      list.className = "mz-suggest-list";
      root.appendChild(list);

      paint(props);

      if (typeof props.mount === "function") {
        unmount = props.mount(root);
      } else {
        // Fallback if mount API missing
        document.body.appendChild(root);
        const rect = props.clientRect?.();
        if (rect) {
          root.style.position = "fixed";
          root.style.left = `${rect.left}px`;
          root.style.top = `${rect.bottom + 4}px`;
          root.style.zIndex = "1000";
        }
        unmount = () => root?.remove();
      }
    },

    onUpdate(props) {
      paint(props);
    },

    onKeyDown({ event }) {
      if (!latest || latest.items.length === 0) {
        if (event.key === "Escape") return true;
        return false;
      }

      if (event.key === "ArrowDown") {
        event.preventDefault();
        select(selected + 1);
        return true;
      }
      if (event.key === "ArrowUp") {
        event.preventDefault();
        select(selected - 1);
        return true;
      }
      if (event.key === "Enter" || event.key === "Tab") {
        event.preventDefault();
        const item = latest.items[selected];
        if (item) latest.command(item);
        return true;
      }
      // Escape: return false so the Suggestion plugin can dismiss itself.
      return false;
    },

    onExit() {
      unmount?.();
      unmount = null;
      root = null;
      list = null;
      latest = null;
      selected = 0;
    },
  };
}
