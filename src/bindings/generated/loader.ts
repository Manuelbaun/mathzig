import { dlopen } from "bun:ffi";
import { existsSync } from "node:fs";
import { generated_symbols } from "./symbols";
import type { Pointer } from "../backend";

const core_symbols = {
  mathzig_create: { args: [], returns: "ptr" },
  mathzig_destroy: { args: ["ptr"], returns: "void" },
  mathzig_get_last_number: { args: [], returns: "f64" },
  mathzig_get_last_tag: { args: [], returns: "u8" },
  mathzig_get_last_ptr: { args: [], returns: "ptr" },
  mathzig_alloc_aligned: { args: ["u64", "u64"], returns: "ptr" },
  mathzig_free: { args: ["ptr"], returns: "void" },
};

export const all_symbols = {
  ...core_symbols,
  ...generated_symbols,
};

let libPath: string | null = null;
let lib: any = null;

export function getLibPath(): string {
  if (libPath) return libPath;
  const possiblePaths = [
    './zig-out/lib/libmathzig.dylib',
    './zig-out/lib/libmathzig.so',
    './zig-out/bin/mathzig.dll',
  ];
  for (const p of possiblePaths) {
    if (existsSync(p)) {
      libPath = p;
      return libPath;
    }
  }
  throw new Error("MathZig library not found.");
}

export function getLib() {
  if (lib) return lib;
  lib = dlopen(getLibPath(), all_symbols);
  return lib;
}
