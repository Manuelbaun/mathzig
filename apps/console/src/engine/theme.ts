export type ThemeTokens = {
  bgApp: string;
  bgInset: string;
  borderSubtle: string;
  fgPrimary: string;
  fgSecondary: string;
  fgMuted: string;
  keyword: string;
  number: string;
  string: string;
  type: string;
  function: string;
  variable: string;
  statusError: string;
  statusSuccess: string;
};

const FALLBACK: ThemeTokens = {
  bgApp: "rgb(28, 29, 34)",
  bgInset: "rgb(22, 23, 28)",
  borderSubtle: "rgb(72, 76, 88)",
  fgPrimary: "rgb(232, 233, 238)",
  fgSecondary: "rgb(168, 172, 184)",
  fgMuted: "rgb(120, 124, 136)",
  keyword: "rgb(100, 180, 230)",
  number: "rgb(140, 210, 160)",
  string: "rgb(220, 180, 100)",
  type: "rgb(100, 200, 210)",
  function: "rgb(220, 210, 120)",
  variable: "rgb(180, 160, 230)",
  statusError: "rgb(230, 120, 110)",
  statusSuccess: "rgb(120, 200, 140)",
};

function readCssColor(cssVar: string, prop: "color" | "backgroundColor" | "borderColor" = "color"): string {
  if (typeof document === "undefined") return "";
  const probe = document.createElement("span");
  probe.style[prop] = `var(${cssVar})`;
  document.documentElement.appendChild(probe);
  const color = getComputedStyle(probe)[prop];
  probe.remove();
  return color;
}

export function readThemeTokens(): ThemeTokens {
  try {
    if (typeof document === "undefined") return { ...FALLBACK };
    return {
      bgApp: readCssColor("--bg-app", "backgroundColor") || FALLBACK.bgApp,
      bgInset: readCssColor("--bg-inset", "backgroundColor") || FALLBACK.bgInset,
      borderSubtle: readCssColor("--border-subtle", "borderColor") || FALLBACK.borderSubtle,
      fgPrimary: readCssColor("--fg-primary") || FALLBACK.fgPrimary,
      fgSecondary: readCssColor("--fg-secondary") || FALLBACK.fgSecondary,
      fgMuted: readCssColor("--fg-muted") || FALLBACK.fgMuted,
      keyword: readCssColor("--color-keyword") || FALLBACK.keyword,
      number: readCssColor("--color-number") || FALLBACK.number,
      string: readCssColor("--color-string") || FALLBACK.string,
      type: readCssColor("--color-type") || FALLBACK.type,
      function: readCssColor("--color-function") || FALLBACK.function,
      variable: readCssColor("--color-variable") || FALLBACK.variable,
      statusError: readCssColor("--status-error") || FALLBACK.statusError,
      statusSuccess: readCssColor("--status-success") || FALLBACK.statusSuccess,
    };
  } catch {
    return { ...FALLBACK };
  }
}

export function chartSeriesColors(theme: ThemeTokens): string[] {
  return [theme.type, theme.keyword, theme.function, theme.string, theme.variable];
}

export function withAlpha(rgbColor: string, alpha = 0.1): string {
  const parts = rgbColor.match(/\d+/g);
  if (!parts || parts.length < 3) return rgbColor;
  return `rgba(${parts[0]}, ${parts[1]}, ${parts[2]}, ${alpha})`;
}

export function chartAxes(theme: ThemeTokens) {
  const axis = { stroke: theme.fgSecondary, grid: { stroke: theme.borderSubtle } };
  return [axis, axis];
}

export function plotlyVelocityScale(theme: ThemeTokens): [number, string][] {
  return [
    [0, theme.type],
    [0.45, theme.keyword],
    [1, theme.statusError],
  ];
}
