import { MathZig } from "./src/mathzig.ts";

async function run() {
    const mz = MathZig.create();

    try {
        console.log("Testing assignment m = [1,2; 3,4]");
        mz.eval("m = [1,2; 3,4]");
        const res = mz.eval("m");
        console.log("Result of m:", res);
        
        const res2 = mz.eval("m * 2");
        console.log("Result of m * 2:", res2);

        console.log("\nTesting inside function:");
        mz.eval("f(x) = { m = [10, 20; 30, 40]; m * x }");
        const res3 = mz.eval("f(2)");
        console.log("Result of f(2):", res3);
    } catch (e) {
        console.error("Error:", e);
    }
}

run();
