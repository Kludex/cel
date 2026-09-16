import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const directory = dirname(fileURLToPath(import.meta.url));
const allWorkloads = JSON.parse(await readFile(resolve(directory, "../workloads.json"), "utf8"));
const { values } = parseArgs({
  options: {
    iterations: { type: "string", default: "100000" },
    warmups: { type: "string", default: "5000" },
    workload: { type: "string" },
  },
});
const workloads = values.workload
  ? allWorkloads.filter((workload) => workload.name === values.workload)
  : allWorkloads;
if (workloads.length === 0) throw new Error(`Unknown workload: ${values.workload}`);
const iterations = Number(values.iterations);
const warmups = Number(values.warmups);
if (![iterations, warmups].every((value) => Number.isSafeInteger(value) && value > 0)) {
  throw new Error("Iterations and warmups must be positive safe integers");
}

const { Program } = await import("../../bindings/typescript/dist/index.js");
const programs = workloads.map((workload) => new Program(workload.expression));
const decisionsPerIteration = workloads.reduce(
  (count, workload) => count + workload.cases.length,
  0,
);

function runIteration() {
  for (let workloadIndex = 0; workloadIndex < workloads.length; workloadIndex += 1) {
    for (const benchmarkCase of workloads[workloadIndex].cases) {
      const result = programs[workloadIndex].evaluate(benchmarkCase.bindings);
      if (result !== benchmarkCase.expected) throw new Error("Decision changed while profiling");
    }
  }
}

for (let iteration = 0; iteration < warmups; iteration += 1) runIteration();
const started = process.hrtime.bigint();
for (let iteration = 0; iteration < iterations; iteration += 1) runIteration();
const elapsed = Number(process.hrtime.bigint() - started);
process.stdout.write(
  `${JSON.stringify({
    workloads: workloads.map((workload) => workload.name),
    decisions: iterations * decisionsPerIteration,
    elapsed_ns: elapsed,
    ns_per_decision: elapsed / (iterations * decisionsPerIteration),
  })}\n`,
);
