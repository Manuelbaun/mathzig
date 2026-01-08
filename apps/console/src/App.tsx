import { Route, Router } from "@solidjs/router";
import { onMount } from "solid-js";
import { Header } from "./components/shell/Header";
import { ConsolePage } from "./pages/ConsolePage";
import { GraphPage } from "./pages/GraphPage";
import { session } from "./state/session";

export default function App() {
  onMount(() => {
    void session.boot();
  });

  return (
    <div class="flex h-full flex-col">
      <Router
        base={import.meta.env.BASE_URL.replace(/\/$/, "")}
        root={(props) => (
          <>
            <Header />
            <div class="relative flex min-h-0 flex-1 flex-col">{props.children}</div>
          </>
        )}
      >
        <Route path="/" component={ConsolePage} />
        <Route path="/graph" component={GraphPage} />
      </Router>
    </div>
  );
}
