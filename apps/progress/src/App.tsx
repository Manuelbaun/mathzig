import { Route, Router } from "@solidjs/router";
import { Layout } from "./components/Layout";
import { OverviewPage } from "./pages/OverviewPage";
import { TrendsPage } from "./pages/TrendsPage";
import { RegressionsPage } from "./pages/RegressionsPage";
import { FeaturesPage } from "./pages/FeaturesPage";
import { VersionsPage } from "./pages/VersionsPage";
import { VersionDetailPage } from "./pages/VersionDetailPage";

export default function App() {
  return (
    <Router root={Layout}>
      <Route path="/" component={OverviewPage} />
      <Route path="/trends" component={TrendsPage} />
      <Route path="/regressions" component={RegressionsPage} />
      <Route path="/features" component={FeaturesPage} />
      <Route path="/versions" component={VersionsPage} />
      <Route path="/versions/:id" component={VersionDetailPage} />
    </Router>
  );
}
