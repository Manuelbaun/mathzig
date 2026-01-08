import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, type Plugin } from "vite";
import solid from "vite-plugin-solid";
import tailwindcss from "@tailwindcss/vite";
import { aotCompilePlugin } from "./vite.aot_plugin.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const stubs = path.join(__dirname, "src/engine/graph/stubs");
const graphSrc = path.resolve(__dirname, "../../src/ts/graph/index.ts");
const tsSrc = path.resolve(__dirname, "../../src/ts");

/**
 * Stub bun:ffi / native MathZig when bundling GraphRunner for the browser.
 * Mirrors tools/build_graph_bundle.ts (scalar graphs work; full-Value host
 * delegation needs bun/native).
 */
function browserNativeStubsPlugin(): Plugin {
  return {
    name: "mathzig-browser-native-stubs",
    enforce: "pre",
    resolveId(id, importer) {
      if (id === "bun:ffi") {
        return path.join(stubs, "bun_ffi.ts");
      }
      // aot_env imports "./mathzig" (and similar relative forms)
      if (
        id === "./mathzig" ||
        id === "../mathzig" ||
        id === "./mathzig.ts" ||
        id === "../mathzig.ts" ||
        id.endsWith("/mathzig") ||
        id.endsWith("/mathzig.ts")
      ) {
        if (importer && (importer.includes(`${path.sep}ts${path.sep}`) || importer.includes("/ts/"))) {
          return path.join(stubs, "mathzig.ts");
        }
      }
      if (
        id.includes("bindings/generated/loader") ||
        id === "./loader" ||
        id.endsWith("/generated/loader")
      ) {
        if (
          importer &&
          (importer.includes("mathzig") || importer.includes("ffi_backend") || importer.includes("stubs"))
        ) {
          return path.join(stubs, "loader.ts");
        }
      }
      if (
        id.includes("bindings/generated/ffi_backend") ||
        id === "./ffi_backend" ||
        id.endsWith("/generated/ffi_backend")
      ) {
        return path.join(stubs, "ffi_backend.ts");
      }
      return null;
    },
  };
}

export default defineConfig({
  plugins: [solid(), tailwindcss(), browserNativeStubsPlugin(), aotCompilePlugin()],
  resolve: {
    alias: {
      "@mathzig/graph": graphSrc,
      // Allow deep imports from shared TS sources when needed
      "@mathzig/ts": tsSrc,
    },
  },
  server: {
    port: 5173,
    fs: { allow: ["../.."] },
  },
  optimizeDeps: {
    include: ["plotly.js-dist-min"],
    exclude: ["@mathzig/graph"],
  },
  build: {
    target: "esnext",
    outDir: "dist",
    commonjsOptions: {
      include: [/plotly\.js-dist-min/, /node_modules/],
    },
  },
});
