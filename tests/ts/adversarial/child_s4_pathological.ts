import { parseGraphDefinitionJson, GraphJsonError } from "../../../src/ts/graph";

// Deeply nested JSON-ish noise + huge claimed structure without full materialization
const junk = '{"nodes":' + "[".repeat(100) + "1" + "]".repeat(100) + "}";
try {
  parseGraphDefinitionJson(junk);
} catch (e) {
  if (!(e instanceof GraphJsonError) && !(e instanceof SyntaxError)) {
    // JSON.parse throws SyntaxError wrapped as GraphJsonError
    if (!(e instanceof GraphJsonError)) {
      console.error(e);
      process.exit(2);
    }
  }
}
// Hostile large node list description as compact JSON
const many = { nodes: Array.from({ length: 50 }, (_, i) => ({ id: `n${i}`, type: "input" })) };
try {
  parseGraphDefinitionJson(JSON.stringify(many));
} catch (e) {
  if (!(e instanceof GraphJsonError)) {
    console.error(e);
    process.exit(2);
  }
}
console.log("ok");
