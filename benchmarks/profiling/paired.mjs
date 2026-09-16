import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: {
    before: { type: "string" },
    after: { type: "string" },
    iterations: { type: "string", default: "5000" },
    workload: { type: "string" },
    workloads: { type: "string" },
    "after-workloads": { type: "string" },
  },
});
if (!values.before || !values.after) throw new Error("Pass --before and --after SDK module paths");
const iterations = Number(values.iterations);
if (!Number.isSafeInteger(iterations) || iterations < 1) throw new Error("Invalid iteration count");
const allWorkloads = JSON.parse(
  await readFile(
    values.workloads ? resolve(values.workloads) : new URL("../workloads.json", import.meta.url),
    "utf8",
  ),
);
const workloads = values.workload
  ? allWorkloads.filter((workload) => workload.name === values.workload)
  : allWorkloads;
if (workloads.length === 0) throw new Error(`Unknown workload: ${values.workload}`);
const afterAll = values["after-workloads"]
  ? JSON.parse(await readFile(resolve(values["after-workloads"]), "utf8"))
  : allWorkloads;
const afterWorkloads = values.workload
  ? afterAll.filter((workload) => workload.name === values.workload)
  : afterAll;
assert.deepEqual(
  afterWorkloads.map((workload) => ({ name: workload.name, cases: workload.cases })),
  workloads.map((workload) => ({ name: workload.name, cases: workload.cases })),
  "Paired policies must use identical named decisions, inputs, and expected results",
);
const decisions = iterations * workloads.reduce((sum, workload) => sum + workload.cases.length, 0);
const engines = [];
for (const name of ["before", "after"]) {
  const { Program } = await import(pathToFileURL(resolve(values[name])).href);
  engines.push({
    name,
    programs: (name === "before" ? workloads : afterWorkloads).map(
      (workload) => new Program(workload.expression),
    ),
    totals: [],
  });
}

for (let sample = -5; sample < 30; sample += 1) {
  const order = sample % 2 === 0 ? engines : [...engines].reverse();
  for (const engine of order) {
    const start = process.hrtime.bigint();
    for (let iteration = 0; iteration < iterations; iteration += 1) {
      for (let index = 0; index < workloads.length; index += 1) {
        for (const test of workloads[index].cases) {
          if (engine.programs[index].evaluate(test.bindings) !== test.expected) {
            throw new Error(`Incorrect decision from ${engine.name}`);
          }
        }
      }
    }
    const elapsed = Number(process.hrtime.bigint() - start);
    if (sample >= 0) engine.totals.push(elapsed);
  }
}

function quantile(data, fraction) {
  const sorted = data.toSorted((a, b) => a - b);
  const position = (sorted.length - 1) * fraction;
  const lower = Math.floor(position);
  return sorted[lower] + (sorted[Math.ceil(position)] - sorted[lower]) * (position - lower);
}

const results = Object.fromEntries(
  engines.map((engine) => {
    const times = engine.totals.map((total) => total / decisions);
    const median = quantile(times, 0.5);
    return [
      engine.name,
      {
        total_ns: engine.totals,
        median_ns_per_decision: median,
        relative_iqr: (quantile(times, 0.75) - quantile(times, 0.25)) / median,
      },
    ];
  }),
);
const ratios = engines[0].totals.map((total, index) => total / engines[1].totals[index]);
process.stdout.write(
  `${JSON.stringify(
    {
      runtime: process.version,
      platform: process.platform,
      architecture: process.arch,
      workloads: workloads.map((workload) => workload.name),
      expressions: {
        before: workloads.map((workload) => workload.expression),
        after: afterWorkloads.map((workload) => workload.expression),
      },
      warmups: 5,
      samples: 30,
      decisions_per_sample: decisions,
      results,
      paired_speedup_ratios: ratios,
      median_paired_speedup: quantile(ratios, 0.5),
    },
    null,
    2,
  )}\n`,
);
