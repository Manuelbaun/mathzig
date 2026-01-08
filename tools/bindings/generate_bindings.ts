import { file, write } from "bun";

// Read API Schema
const schemaPath = "src/bindings/generated/api.json";
const schemaFile = file(schemaPath);
if (!await schemaFile.exists()) {
    console.error(`Schema file not found: ${schemaPath}`);
    process.exit(1);
}

const schema = await schemaFile.json();

// Helper to map Zig types to FFIType strings
function mapToFFIType(zigType: string): string {
    if (zigType === "u32") return '"u32"';
    if (zigType === "i32") return '"i32"';
    if (zigType === "u64") return '"u64"';
    if (zigType === "i64") return '"i64"';
    if (zigType === "f64") return '"f64"';
    if (zigType === "u8") return '"u8"';
    if (zigType === "bool") return '"bool"';
    if (zigType === "void") return '"void"';
    if (zigType === "usize") return '"u64"'; // Assuming 64-bit
    
    // Check for explicit sentinel (C-string)
    if (zigType.includes(":0") && zigType.includes("u8")) {
        return '"cstring"';
    }

    if (zigType.startsWith("[*]") || zigType.startsWith("[]") || zigType.startsWith("?[*]")) return '"ptr"';  
    if (zigType === "mem.Allocator") return '"ptr"';
    if (zigType === "Allocator") return '"ptr"';
    
    if (zigType.includes("error_set!")) {
        const successType = zigType.split("!").pop();
        return mapToFFIType(successType || "void");
    }
    return '"ptr"'; 
}

function mapToTSType(zigType: string): string {
    // Numeric types
    if (["u32", "i32", "u64", "i64", "f64", "usize", "u8", "u24", "u16", "i16"].includes(zigType)) return "number";
    if (zigType === "bool") return "boolean";
    if (zigType === "void") return "void";
    
    // Sentinel-terminated string pointers (cstrings) → string
    if (zigType.includes(":0") && zigType.includes("u8")) {
        return "string";
    }
    
    // Known class types - handle pointers and optionals
    const knownClasses = ["MathZig", "CompiledExpr", "Value", "Series", "Record", "Matrix", "Vector"];
    for (const cls of knownClasses) {
        if (zigType === cls || zigType === `*${cls}` || zigType === `?*${cls}`) {
            return cls;
        }
    }
    
    // Non-cstring u8 arrays (byte buffers)
    if (zigType.includes("u8") && (zigType.includes("[*]") || zigType.includes("[]"))) {
        return "string | Uint8Array | Pointer";
    }

    // f64 arrays/slices
    if (zigType.startsWith("[]") || zigType.startsWith("[*]")) return "Float64Array | Pointer";
    
    // Pointer to a type
    if (zigType.startsWith("*")) return zigType.substring(1);
    
    // Opaque pointers
    if (zigType === "?*anyopaque") return "Pointer";
    
    // Fallback
    return "any";
}

const classNames = Object.keys(schema.classes);
function isClass(type: string): boolean {
    return classNames.includes(type.split(" | ")[0]);
}

const pointerTypeDecl = `import type { Backend, Pointer } from "../backend";\n`;

// =============================================================================
// Generate symbols.ts
// =============================================================================

let symbolsOutput = `\n`;
symbolsOutput += `export const generated_symbols = {
`;

for (const className in schema.classes) {
    const classDef = schema.classes[className];
    for (const method of classDef.methods) {
        if (!method.export_name) continue;

        const args = method.args.map((arg: any) => mapToFFIType(arg.ffi_type));
        const ret = mapToFFIType(method.ffi_return_type);

        symbolsOutput += `  ${method.export_name}: { args: [${args.join(", ")}], returns: ${ret} },\n`;
    }
}

// Add memory helpers to symbols
symbolsOutput += `  wasm_malloc: { args: ["u64"], returns: "ptr" },\n`;
symbolsOutput += `  wasm_free: { args: ["ptr"], returns: "void" },\n`;

symbolsOutput += `};
`;

await write("src/bindings/generated/symbols.ts", symbolsOutput);
console.log("Generated src/bindings/generated/symbols.ts");

// =============================================================================
// Generate loader.ts
// =============================================================================

let loaderOutput = `import { dlopen } from "bun:ffi";
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
`;

await write("src/bindings/generated/loader.ts", loaderOutput);
console.log("Generated src/bindings/generated/loader.ts");

// =============================================================================
// Generate classes.ts
// =============================================================================

let classesOutput = pointerTypeDecl + "\n";

for (const className in schema.classes) {
    const classDef = schema.classes[className];

    if (className === "Globals") continue;

    classesOutput += `export class ${className} {
`;
    
    const isDataWrapper = className === "Matrix" || className === "Vector";

    if (className === "Matrix") {
        classesOutput += `  public data: Float64Array;
  public rows: number;
  public cols: number;
  public stride: number;

  constructor(public backend: Backend, rows: number, cols: number, data?: Float64Array) {
    this.rows = rows;
    this.cols = cols;
    this.stride = cols;
    if (data) {
      this.data = data;
    } else {
      const p = backend.call("mathzig_alloc_aligned", 32n, BigInt(rows * cols * 8));
      if (!p) throw new Error("Failed to allocate matrix data");
      this.data = new Float64Array(backend.toArrayBuffer(p, rows * cols * 8), 0, rows * cols);
    }
  }
`;
    } else if (className === "Vector") {
        classesOutput += `  public data: Float64Array;
  public len: number;
  constructor(public backend: Backend, dataOrLen: Float64Array | number) {
    if (typeof dataOrLen === "number") {
      this.len = dataOrLen;
      const p = backend.call("mathzig_alloc_aligned", 32n, BigInt(dataOrLen * 8));
      if (!p) throw new Error("Failed to allocate vector data");
      this.data = new Float64Array(backend.toArrayBuffer(p, dataOrLen * 8), 0, dataOrLen);
    } else {
      this.data = dataOrLen;
      this.len = dataOrLen.length;
    }
  }
`;
    } else {
        classesOutput += `  public handle: Pointer;
`;
        if (className === "Value") {
            classesOutput += `  public tag: number;
  public num: number;
  public owner?: any; // To avoid circular dependency
`;
        }
        classesOutput += `  constructor(public backend: Backend, handle: Pointer${className === "Value" ? ", tag?: number, num?: number, owner?: any" : ""}) {
`;
        classesOutput += `    this.handle = handle;
`;
        if (className === "Value") {
            classesOutput += `    this.tag = tag ?? Number(backend.call("mathzig_get_last_tag"));
    this.num = num ?? Number(backend.call("mathzig_get_last_number"));
    this.owner = owner;
`;
        }
        classesOutput += `  }

`;

        if (className === "Value") {
            classesOutput += `  get value(): any {
    if (this.tag === 0) return this.num;
    if (this.tag === 7) return this.num !== 0;
    if (this.tag === 13) return null;
    if (this.tag === 12) return undefined;
    if (this.tag === 10) return new Record(this.backend, this.handle);
    if (this.tag === 4) return new Series(this.backend, this.handle);
    if (this.tag === 3) return new Matrix(this.backend, 0, 0, undefined); // handle will be used, rows/cols might need separate fetch if not in Value
    return this;
  }

  retain(): void {
    this.backend.call("mathzig_retain", this.handle, this.tag);
  }

  release(): void {
    this.backend.call("mathzig_release", this.handle, this.tag);
  }

  toNumber(): number {
    return Number(this.backend.call("mathzig_value_to_number", this.handle, this.tag));
  }
`;
        }

        if (className === "MathZig") {
            classesOutput += `  static create(backend: Backend): MathZig {
    const h = backend.call("mathzig_create");
    if (!h) throw new Error("Failed to create MathZig context");
    return new MathZig(backend, h);
  }

  destroy(): void {
    this.backend.call("mathzig_destroy", this.handle);
  }
`;
        }
    }

    // Methods
    for (const method of classDef.methods) {
        if (!method.export_name) continue;
        if (className === "Value" && (method.name === "retain" || method.name === "release" || method.name === "toNumber")) continue;

        const methodArgs: {name: string, type: string}[] = [];
        const callArgs: string[] = [];
        const preCall: string[] = [];
        const postCall: string[] = [];
        const seenArgNames = new Set();
        
        let returnType = mapToTSType(method.return_type);

        let hasOut = false;
        for (const arg of method.args) {
            if (arg.binding && arg.binding.startsWith("out.")) {
                hasOut = true;
            }
        }
        
        const knownRawBindings = ["u32", "i32", "u64", "i64", "f64", "usize", "u8", "bool", "string", "[*]const f64", "[*]f64", "[]const f64", "[]f64", "[*]u8"];

        // Build Args & Call logic
        for (const arg of method.args) {
            const binding = arg.binding;
            const argName = arg.name;
            const argType = mapToTSType(arg.type);

            if (binding === "this") {
                if (isDataWrapper) callArgs.push("this.backend.ptr(this.data)");
                else callArgs.push("this.handle");
            }
            else if (binding === "other") {
                const tsType = mapToTSType(arg.type);
                if (!seenArgNames.has(argName)) {
                    methodArgs.push({ name: argName, type: tsType });
                    seenArgNames.add(argName);
                }
                const isOtherDataWrapper = tsType === "Matrix" || tsType === "Vector";
                if (isOtherDataWrapper) callArgs.push(`this.backend.ptr(${argName}.data)`);
                else callArgs.push(`${argName}.handle`);
            }
            else if (binding === "context") {
                if (!seenArgNames.has("ctx")) {
                    methodArgs.push({ name: "ctx", type: "MathZig" });
                    seenArgNames.add("ctx");
                }
                callArgs.push("ctx.handle");
            }
            else if (binding === "string") {
                if (!seenArgNames.has(argName)) {
                    methodArgs.push({ name: argName, type: "string" });
                    seenArgNames.add(argName);
                }
                preCall.push(`    const ${argName}_ptr = this.backend.ptr(${argName});`);
                callArgs.push(`${argName}_ptr`);
                postCall.push(`    this.backend.freeTemporary(${argName}_ptr);`);
            }
            else if (binding === "out_tag") {
                preCall.push(`    const tagBuf = new Uint8Array(1);`);
                preCall.push(`    const tagBuf_ptr = this.backend.ptr(tagBuf);`);
                callArgs.push("tagBuf_ptr");
                postCall.push(`    this.backend.freeTemporary(tagBuf_ptr);`);
            }
            else if (binding === "this.rows") callArgs.push("this.rows");
            else if (binding === "this.cols") callArgs.push("this.cols");
            else if (binding === "this.len") callArgs.push("this.len");
            else if (binding === "this.stride") callArgs.push("this.stride || this.cols");
            else if (binding === "this.data") {
                preCall.push(`    const data_ptr = this.backend.ptr(this.data);`);
                callArgs.push("data_ptr");
                postCall.push(`    this.backend.freeTemporary(data_ptr);`);
            }
            
            else if (binding.startsWith("other.")) {
                const parts = binding.split(".");
                const otherName = parts[0];
                const field = parts[1];
                if (!seenArgNames.has(otherName)) {
                    methodArgs.push({ name: otherName, type: argType === "Matrix" ? "Matrix" : (argType === "Vector" ? "Vector" : className) });
                    seenArgNames.add(otherName);
                }
                if (field === "data") callArgs.push(`this.backend.ptr(${otherName}.data)`);
                else if (field === "stride") callArgs.push(`${otherName}.stride || ${otherName}.cols`);
                else callArgs.push(`${otherName}.${field}`);
            }
            else if (binding.startsWith("out.")) {
                const parts = binding.split(".");
                const field = parts[1];
                if (field === "data") callArgs.push(`this.backend.ptr(result.data)`);
                else if (field === "stride") callArgs.push(`result.stride || result.cols`);
                else callArgs.push(`result.${field}`);
            }
            else if (binding === "scalar" || binding === "f64") {
                if (!seenArgNames.has(argName)) {
                    methodArgs.push({ name: argName, type: "number" });
                    seenArgNames.add(argName);
                }
                callArgs.push(argName);
            }
            else if (binding === "context.allocator") {
                callArgs.push("0"); 
            }
            else if (knownRawBindings.includes(binding)) {
                if (!seenArgNames.has(argName)) {
                    methodArgs.push({ name: argName, type: mapToTSType(binding) });
                    seenArgNames.add(argName);
                }
                if (binding.includes("[*]") || binding.includes("[]")) {
                    callArgs.push(`this.backend.ptr(${argName})`);
                } else {
                    callArgs.push(argName);
                }
            }
            else {
                if (binding.startsWith("this.")) {
                     callArgs.push(`this.${binding.split(".")[1]}`);
                } else {
                    if (!seenArgNames.has(argName)) {
                        methodArgs.push({ name: argName, type: argType });
                        seenArgNames.add(argName);
                    }
                    callArgs.push(argName);
                }
            }
        }

        if (hasOut) {
            if (!seenArgNames.has("out")) {
                methodArgs.push({ name: "out", type: `${className} | undefined` });
                seenArgNames.add("out");
            }
            returnType = className;
        }

        // Method Body
        const needsCleanup = postCall.length > 0;
        const indent = needsCleanup ? "      " : "    ";

        classesOutput += `  ${method.name}(${methodArgs.map(a => `${a.name}: ${a.type}`).join(", ")}): ${returnType} {
`;
        classesOutput += preCall.join("\n") + (preCall.length ? "\n" : "");

        if (needsCleanup) {
            classesOutput += `    try {\n`;
        }

        if (hasOut) {
             if (className === "Matrix") {
                 classesOutput += `${indent}const result = out || new Matrix(this.backend, this.rows, (other as any)?.cols || this.cols);
`;
             } else if (className === "Vector") {
                 classesOutput += `${indent}const result = out || new Vector(this.backend, new Float64Array(this.data.length));
`;
             } else {
                 classesOutput += `${indent}const result = out!;
`;
             }
        }

        if (method.return_type === "Value") {
            const isMathZig = className === "MathZig";
            const contextArg = method.args.find((a: any) => a.binding === "context");

            classesOutput = classesOutput.replace(
                new RegExp(`${method.name}\(([^)]*)\): ${returnType}`),
                `${method.name}($1): any`
            );
            classesOutput += `${indent}this.backend.call("${method.export_name}"${callArgs.length ? ", " + callArgs.join(", ") : ""});
${indent}const tag = Number(this.backend.call("mathzig_get_last_tag"));
${indent}const num = Number(this.backend.call("mathzig_get_last_number"));
`;

            if (isMathZig) {
                classesOutput += `${indent}if (tag === 14) throw new Error(\`MathZig error in ${method.name}: \${this.getError()}\`);\n`;
            } else if (contextArg) {
                classesOutput += `${indent}if (tag === 14) throw new Error(\`MathZig error in ${method.name}: \${${contextArg.name}.getError()}\`);\n`;
            } else {
                classesOutput += `${indent}if (tag === 14) throw new Error(\`MathZig error in ${method.name}\`);\n`;
            }

            classesOutput += `${indent}if (tag === 0) return num; // Number
${indent}if (tag === 7) return num !== 0; // Boolean
${indent}if (tag === 13) return null; // Null
${indent}if (tag === 12) return undefined; // Undefined
`;

            const ctxHandle = isMathZig ? "this" : (contextArg ? `${contextArg.name}` : "undefined");
            classesOutput += `${indent}const p = this.backend.call("mathzig_get_last_ptr") || 0;
${indent}const v = new Value(this.backend, p, tag, num, ${ctxHandle});
${indent}// Retain ref-counted types because last_value will be released on next call
${indent}if (tag === 3 || tag === 4 || tag === 10 || tag === 9) { // Matrix, Series, Record, Array
${indent}    v.retain();
${indent}}
${indent}return v;
`;
        }
        else if (returnType !== "void" && !hasOut) {
            if (isClass(returnType)) {
                classesOutput += `${indent}const res = this.backend.call("${method.export_name}"${callArgs.length ? ", " + callArgs.join(", ") : ""});\n`;
                classesOutput += `${indent}if (!res) throw new Error(\`MathZig error in ${method.name}: \${this instanceof MathZig ? (this as any).getError() : 'Failed to create handle'}\`);\n`;
                classesOutput += `${indent}return new ${returnType}(this.backend, res);\n`;
            } else if (returnType === "Float64Array") {
                classesOutput += `${indent}const res = this.backend.call("${method.export_name}"${callArgs.length ? ", " + callArgs.join(", ") : ""});
`;
                if (method.name === "getVariablesPtr") {
                    classesOutput += `${indent}return new Float64Array(this.backend.toArrayBuffer(res, 256 * 8), 0, 256);
`;
                } else {
                    classesOutput += `${indent}return res;
`;
                }
            } else {
                const resCall = `this.backend.call("${method.export_name}"${callArgs.length ? ", " + callArgs.join(", ") : ""})`;
                if (["u64", "usize", "i64", "u32", "i32", "u24", "u16", "i16"].includes(method.return_type)) {
                    classesOutput += `${indent}const res = ${resCall};
`;
                    classesOutput += `${indent}return typeof res === "bigint" || typeof res === "number" ? Number(res) : res;
`;
                } else if (method.return_type.includes(":0") && method.return_type.includes("u8")) {
                    classesOutput += `${indent}return this.backend.readString(${resCall});
`;
                }
                else {
                    classesOutput += `${indent}return ${resCall};
`;
                }
            }
        }
        else {
            classesOutput += `${indent}this.backend.call("${method.export_name}"${callArgs.length ? ", " + callArgs.join(", ") : ""});
`;
        }

        if (hasOut) {
            classesOutput += `${indent}return result;
`;
        }

        if (needsCleanup) {
            classesOutput += `    } finally {\n`;
            classesOutput += postCall.join("\n") + "\n";
            classesOutput += `    }\n`;
        }

        classesOutput += `  }

`;
    }
    
    classesOutput += `}

`;
}

await write("src/bindings/generated/classes.ts", classesOutput);
console.log("Generated src/bindings/generated/classes.ts");

// =============================================================================
// Generate aot_env.ts from aot_abi.json
// =============================================================================

const aotAbiPath = "src/bindings/generated/aot_abi.json";
const aotAbiFile = file(aotAbiPath);
if (!await aotAbiFile.exists()) {
    console.error(`AOT ABI file not found: ${aotAbiPath} (run zig build abi-aot first)`);
    process.exit(1);
}
const aotAbi = await aotAbiFile.json();

let aotEnvOutput = `// AUTO-GENERATED from src/bindings/generated/aot_abi.json — do not edit.\n`;
aotEnvOutput += `import type { AotHostEnv } from "../../ts/aot_env";\n\n`;
aotEnvOutput += `export type GeneratedAotStub = (...args: number[]) => number;\n\n`;
aotEnvOutput += `const FAST_SCALAR: Record<string, GeneratedAotStub> = {\n`;
aotEnvOutput += `  pow: Math.pow,\n`;
// Euclidean modulo (result in [0,|b|)) — matches VM euclideanMod, not JS % (sign of dividend).
aotEnvOutput += `  fmod: (a: number, b: number) => a - Math.abs(b) * Math.floor(a / Math.abs(b)),\n`;

// Builtins with a direct JS Math equivalent get a zero-FFI fast path.
const MATH_EQUIVALENTS = ["abs","sin","cos","tan","asin","acos","atan","atan2","sqrt","cbrt","exp","log10","log2","log1p","expm1","floor","ceil","round","sign","min","max","hypot","sinh","cosh","tanh","asinh","acosh","atanh"];
// Fast-path builtins that can also receive matrix/any args — the delegated
// stub must win so non-scalar inputs reach the engine.
const DELEGATE_ANYWAY = ["sqrt", "round", "min", "max", "abs"];
const fastEmitted = new Set<string>(["pow", "fmod"]);

for (const [name, spec] of Object.entries(aotAbi.builtins as Record<string, any>)) {
    if (!spec.supported || !spec.fast_scalar) continue;
    if (!MATH_EQUIVALENTS.includes(name)) continue; // no JS equivalent -> delegated below
    fastEmitted.add(name);
    if (name === "abs") {
        aotEnvOutput += `  abs: (x: number) => Math.abs(x),\n`;
    } else {
        aotEnvOutput += `  ${name}: (Math as any).${name},\n`;
    }
}
aotEnvOutput += `};\n\n`;

aotEnvOutput += `export function buildGeneratedAotStubs(host: AotHostEnv): Record<string, GeneratedAotStub> {\n`;
aotEnvOutput += `  const stubs: Record<string, GeneratedAotStub> = { ...FAST_SCALAR };\n`;

// Stubs are variadic: a wasm module calls an import with the exact arity it
// declared, which may be less than the builtin's max arity. Fixed-arity
// params would leave trailing args undefined -> NaN in the wire buffer.
// Every supported builtin without a fast path MUST get a delegated stub, or
// modules importing it fail to instantiate.
for (const [name, spec] of Object.entries(aotAbi.builtins as Record<string, any>)) {
    if (!spec.supported) continue;
    if (fastEmitted.has(name) && !DELEGATE_ANYWAY.includes(name)) continue;
    aotEnvOutput += `  stubs["${name}"] = (...args: number[]) => host.callDelegated("${name}", args);\n`;
    if (spec.where_capable) {
        aotEnvOutput += `  stubs["${name}_where"] = (...args: number[]) => host.callDelegated("${name}", args.slice(0, -1), args[args.length - 1] ?? 0);\n`;
    }
}

aotEnvOutput += `  return stubs;\n`;
aotEnvOutput += `}\n`;

await write("src/bindings/generated/aot_env.ts", aotEnvOutput);
console.log("Generated src/bindings/generated/aot_env.ts");
