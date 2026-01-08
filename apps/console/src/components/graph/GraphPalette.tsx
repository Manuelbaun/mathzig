import { NODE_KIND_META, type NodeKind } from "../../engine/graph/node_draft";
import { PALETTE_MIME } from "./constants";

type Props = {
  onAdd: (kind: NodeKind) => void;
};

export function GraphPalette(props: Props) {
  return (
    <div class="flex flex-wrap items-center gap-1.5" role="group" aria-label="Add node">
      {NODE_KIND_META.map((item) => (
        <button
          type="button"
          class="ghost-btn cursor-grab active:cursor-grabbing"
          draggable
          onDragStart={(e) => {
            e.dataTransfer?.setData(PALETTE_MIME, item.kind);
            e.dataTransfer?.setData("text/plain", item.kind);
            if (e.dataTransfer) e.dataTransfer.effectAllowed = "copy";
          }}
          onClick={() => props.onAdd(item.kind)}
          title={`${item.title} (drag onto canvas or click)`}
          aria-label={`Add ${item.label} node (${item.group})`}
        >
          + {item.label}
        </button>
      ))}
    </div>
  );
}
