/** Child entry for S1 deadline test — must finish or be killed. */
import { parseGraphDsl, DslError } from "../../../src/ts/graph";

const deep = "a = " + "(".repeat(10_000) + "1" + ")".repeat(10_000) + ";";
try {
  parseGraphDsl(deep);
} catch (e) {
  if (!(e instanceof DslError)) {
    console.error("unexpected", e);
    process.exit(2);
  }
}
console.log("ok");
