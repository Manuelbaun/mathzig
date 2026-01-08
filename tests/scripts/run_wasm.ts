import { readFile } from "fs/promises";

async function main() {
  try {
    const wasmBuffer = await readFile(new URL("../artifacts/wasm/test.wasm", import.meta.url));
    const wasmModule = await WebAssembly.compile(wasmBuffer);
    
    // Create an empty env object for imports if needed (though x+y shouldn't need any)
    const importObject = {
        env: {}
    };

    const instance = await WebAssembly.instantiate(wasmModule, importObject);

    // The default exported function name from the CLI is "eval"
    const { eval: evalFn } = instance.exports as any;
    
    if (typeof evalFn !== 'function') {
        console.error("Export 'eval' not found or not a function");
        // Log available exports for debugging
        console.log("Available exports:", Object.keys(instance.exports));
        return;
    }

    // Call the function with arguments x=10, y=32
    // The compiler was run with -p 2, so it expects 2 arguments.
    const x = 10;
    const y = 32;
    const result = evalFn(x, y);
    
    console.log(`WASM Execution Result:`);
    console.log(`${x} + ${y} = ${result}`);
    
    if (result === x + y) {
        console.log("SUCCESS: Result matches expected value.");
    } else {
        console.error("FAILURE: Result does not match expected value.");
    }

  } catch (e) {
      console.error("Error running WASM:", e);
  }
}

main();
