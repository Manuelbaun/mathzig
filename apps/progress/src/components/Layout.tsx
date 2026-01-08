import type { ParentProps } from "solid-js";
import { For } from "solid-js";
import { A, useLocation } from "@solidjs/router";

const NAV: Array<{ href: string; label: string; end?: boolean }> = [
  { href: "/", label: "Overview", end: true },
  { href: "/trends", label: "Trends" },
  { href: "/regressions", label: "Regressions" },
  { href: "/features", label: "Features" },
  { href: "/versions", label: "Versions" },
];

export function Layout(props: ParentProps) {
  const loc = useLocation();

  const isActive = (href: string, end?: boolean) => {
    if (end) return loc.pathname === href;
    return loc.pathname === href || loc.pathname.startsWith(`${href}/`);
  };

  return (
    <div class="flex h-full min-h-0 flex-col">
      <header class="flex min-h-12 shrink-0 flex-wrap items-center justify-between gap-2 border-b border-line bg-panel px-3 py-2 select-none sm:px-4">
        <div class="flex min-w-0 items-center gap-2.5">
          <div class="flex items-center gap-2 font-semibold text-fg">
            <div class="flex h-5 w-5 items-center justify-center rounded-sm bg-keyword font-mono text-sm font-bold text-app">
              Z
            </div>
            <span class="tracking-tight">MathZig</span>
            <span class="text-fg-muted font-normal">Progress</span>
          </div>
          <nav class="ml-2 flex flex-wrap items-center gap-1 text-xs" aria-label="Primary">
            <For each={NAV}>
              {(item) => (
                <A
                  href={item.href}
                  class="rounded-md px-2.5 py-1.5 transition-colors"
                  classList={{
                    "bg-active text-fg": isActive(item.href, item.end),
                    "text-fg-secondary hover:bg-raised hover:text-fg": !isActive(
                      item.href,
                      item.end
                    ),
                  }}
                  end={item.end}
                >
                  {item.label}
                </A>
              )}
            </For>
          </nav>
        </div>
        <div class="text-[11px] text-fg-muted font-mono">localhost:5174</div>
      </header>
      <main class="relative flex min-h-0 flex-1 flex-col overflow-auto p-4 sm:p-6">
        {props.children}
      </main>
    </div>
  );
}
