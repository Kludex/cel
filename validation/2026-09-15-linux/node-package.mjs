import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CELType, Environment, Program } from "@pydantic/cel";

const workloads = JSON.parse(readFileSync(process.argv[2], "utf8"));
let decisions = 0;
for (const workload of workloads) {
  const variables = Object.fromEntries(
    workload.cases.flatMap((entry) =>
      Object.keys(entry.bindings).map((name) => [name, new CELType("dyn")]),
    ),
  );
  const environment = new Environment({ variables });
  for (const program of [new Program(workload.expression), environment.compile(workload.expression)]) {
    for (const entry of workload.cases) {
      assert.equal(program.evaluate(entry.bindings), entry.expected, `${workload.name}/${entry.name}`);
      decisions += 1;
    }
  }
}
assert.equal(decisions, 78);
console.log(JSON.stringify({
  node: process.version,
  glibc: process.report.getReport().header.glibcVersionRuntime,
  decisions,
}));
