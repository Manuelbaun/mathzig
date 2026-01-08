/**
 * Linear undo/redo stack for EditorDocument snapshots.
 */
import type { EditorDocument } from "./editor_types";

const MAX = 80;

export type HistorySnapshot = {
  doc: EditorDocument;
  label: string;
};

export class DocumentHistory {
  private past: HistorySnapshot[] = [];
  private future: HistorySnapshot[] = [];
  private current: HistorySnapshot;

  constructor(initial: EditorDocument, label = "initial") {
    this.current = { doc: cloneDoc(initial), label };
  }

  get present(): EditorDocument {
    return this.current.doc;
  }

  get canUndo(): boolean {
    return this.past.length > 0;
  }

  get canRedo(): boolean {
    return this.future.length > 0;
  }

  get undoLabel(): string | null {
    return this.past.length > 0 ? this.past[this.past.length - 1]!.label : null;
  }

  get redoLabel(): string | null {
    return this.future.length > 0 ? this.future[0]!.label : null;
  }

  /** Push current state, then apply next as present. */
  commit(next: EditorDocument, label = "edit"): EditorDocument {
    this.past.push(this.current);
    if (this.past.length > MAX) this.past.shift();
    this.future = [];
    this.current = { doc: cloneDoc(next), label };
    return this.current.doc;
  }

  /** Replace present without a history entry (e.g. intermediate drag). */
  replacePresent(next: EditorDocument, label?: string): EditorDocument {
    this.current = {
      doc: cloneDoc(next),
      label: label ?? this.current.label,
    };
    return this.current.doc;
  }

  undo(): EditorDocument | null {
    if (this.past.length === 0) return null;
    this.future.unshift(this.current);
    this.current = this.past.pop()!;
    return cloneDoc(this.current.doc);
  }

  redo(): EditorDocument | null {
    if (this.future.length === 0) return null;
    this.past.push(this.current);
    this.current = this.future.shift()!;
    return cloneDoc(this.current.doc);
  }

  reset(doc: EditorDocument, label = "reset"): void {
    this.past = [];
    this.future = [];
    this.current = { doc: cloneDoc(doc), label };
  }
}

function cloneDoc(doc: EditorDocument): EditorDocument {
  return structuredClone(doc);
}
