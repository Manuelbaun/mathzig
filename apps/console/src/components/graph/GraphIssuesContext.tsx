import { createContext, useContext, type Accessor } from "solid-js";
import type { ValidationIssue } from "../../engine/graph/validate_editor";

export type GraphIssuesApi = {
  issues: Accessor<ValidationIssue[]>;
  issuesFor: (nodeId: string) => ValidationIssue[];
  missingPorts: (nodeId: string) => Set<string>;
  /** Source port kind while connecting, or null. */
  connectFromKind: Accessor<string | null>;
};

const GraphIssuesContext = createContext<GraphIssuesApi | null>(null);

export function GraphIssuesProvider(props: {
  value: GraphIssuesApi;
  children: import("solid-js").JSX.Element;
}) {
  return (
    <GraphIssuesContext.Provider value={props.value}>
      {props.children}
    </GraphIssuesContext.Provider>
  );
}

export function useGraphIssues(): GraphIssuesApi | null {
  return useContext(GraphIssuesContext);
}
