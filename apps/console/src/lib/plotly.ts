/**
 * Plotly loader + plain-object helpers.
 * Never pass Solid store proxies into Plotly — it mutates traces/layout and
 * throws "Cannot set properties of undefined (setting 'x')" on proxies.
 */

let PlotlyMod: any = null;

export async function getPlotly(): Promise<any> {
  if (PlotlyMod) return PlotlyMod;
  const mod: any = await import("plotly.js-dist-min");
  const candidate = mod?.default ?? mod?.Plotly ?? mod;
  if (typeof candidate?.newPlot !== "function") {
    throw new Error("plotly.js-dist-min: newPlot missing (bad interop)");
  }
  PlotlyMod = candidate;
  return PlotlyMod;
}

/** Deep clone into plain JSON-safe values (drops proxies / typed arrays). */
export function plainClone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

export function purgePlotly(el: HTMLElement | undefined | null) {
  if (!el || !PlotlyMod?.purge) return;
  try {
    PlotlyMod.purge(el);
  } catch {
    /* ignore */
  }
}
