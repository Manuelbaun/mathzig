import { test, expect } from "bun:test";
import { runParity } from "../parity/cli";

test("Unified Parity (quick subset)", async () => {
  const { results } = await runParity({ taskId: "quick", quick: true });
  const failures: string[] = [];

  for (const [backend, cases] of Object.entries(results)) {
    for (const [caseId, res] of Object.entries(cases)) {
      if (res.status === "FAIL") failures.push(`${backend}:${caseId} ${res.reason ?? ""}`);
    }
  }

  expect(failures.length).toBe(0);
});
