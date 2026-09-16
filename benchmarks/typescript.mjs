import { mkdir, readFile, writeFile } from "node:fs/promises";
import { cpus, platform, release } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const benchmarkDirectory = dirname(fileURLToPath(import.meta.url));

async function loadWorkloads() {
  return JSON.parse(await readFile(resolve(benchmarkDirectory, "workloads.json"), "utf8"));
}

async function loadEngine(engine) {
  if (
    [
      "candidate",
      "candidate-checked",
      "candidate-protobuf",
      "candidate-maps",
      "candidate-functions",
      "candidate-plain",
    ].includes(engine)
  ) {
    let candidate;
    try {
      candidate = await import("../bindings/typescript/dist/index.js");
    } catch (error) {
      throw new Error("The candidate is not built. Build bindings/typescript first.", {
        cause: error,
      });
    }
    let version = "source tree";
    try {
      const packageData = JSON.parse(
        await readFile(resolve(benchmarkDirectory, "../bindings/typescript/package.json"), "utf8"),
      );
      version = packageData.version ?? version;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const names = new Set(
      (await loadWorkloads()).flatMap((workload) =>
        workload.cases.flatMap((entry) => Object.keys(entry.bindings)),
      ),
    );
    const environment =
      engine === "candidate-checked" ||
      engine === "candidate-protobuf" ||
      engine === "candidate-functions"
        ? new candidate.Environment({
            variables: Object.fromEntries(
              [...names].sort().map((name) => [name, new candidate.CELType("dyn")]),
            ),
            functions:
              engine === "candidate-functions"
                ? [
                    new candidate.FunctionDeclaration(
                      "is_allowed",
                      Array.from({ length: 3 }, () => new candidate.CELType("string")),
                      new candidate.CELType("bool"),
                      (role, owner, identity) => role === "admin" || owner === identity,
                    ),
                  ]
                : [],
          })
        : undefined;
    const protobuf =
      engine === "candidate-protobuf" ? await import("@bufbuild/protobuf") : undefined;
    const wkt =
      engine === "candidate-protobuf" ? await import("@bufbuild/protobuf/wkt") : undefined;
    function typedMaps(value) {
      if (Array.isArray(value)) return value.map(typedMaps);
      if (value !== null && typeof value === "object") {
        return new Map(Object.entries(value).map(([key, item]) => [key, typedMaps(item)]));
      }
      return value;
    }
    return {
      compile: (expression) =>
        environment ? environment.compile(expression) : new candidate.Program(expression),
      evaluate: (program, bindings) => {
        if (engine === "candidate-maps") {
          bindings = Object.fromEntries(
            Object.entries(bindings).map(([key, value]) => [key, typedMaps(value)]),
          );
        }
        if (protobuf) {
          bindings = Object.fromEntries(
            Object.entries(bindings).map(([name, value]) => [
              name,
              new candidate.Message(
                "google.protobuf.Struct",
                protobuf.toBinary(wkt.StructSchema, protobuf.fromJson(wkt.StructSchema, value)),
              ),
            ]),
          );
        }
        return engine === "candidate-plain"
          ? program.evaluate(bindings, { plainData: true })
          : program.evaluate(bindings);
      },
      version,
    };
  }

  if (engine === "cel-js") {
    const baseline = await import("@marcbachmann/cel-js");
    const packageData = JSON.parse(
      await readFile(
        resolve(benchmarkDirectory, "node_modules/@marcbachmann/cel-js/package.json"),
        "utf8",
      ),
    );
    const environment = new baseline.Environment({
      unlistedVariablesAreDyn: true,
      enableOptionalTypes: true,
    });
    return {
      compile: (expression) => environment.parse(expression),
      evaluate: (program, bindings) => program(bindings),
      version: packageData.version,
    };
  }

  let baseline;
  try {
    baseline = await import("@bufbuild/cel");
  } catch (error) {
    throw new Error("Install the optional baseline with `npm install --prefix benchmarks`.", {
      cause: error,
    });
  }
  const environment = baseline.celEnv();
  const packageData = JSON.parse(
    await readFile(resolve(benchmarkDirectory, "node_modules/@bufbuild/cel/package.json"), "utf8"),
  );
  return {
    compile: (expression) => baseline.plan(environment, baseline.parse(expression)),
    evaluate: (program, bindings) => {
      const result = program(bindings);
      if (baseline.isCelError(result)) throw result;
      return result;
    },
    version: packageData.version,
  };
}

function verify(workloads, programs, evaluate) {
  let decisions = 0;
  for (let workloadIndex = 0; workloadIndex < workloads.length; workloadIndex += 1) {
    const workload = workloads[workloadIndex];
    for (const benchmarkCase of workload.cases) {
      const actual = evaluate(programs[workloadIndex], benchmarkCase.bindings);
      if (actual !== benchmarkCase.expected) {
        throw new Error(
          `${workload.name}/${benchmarkCase.name}: expected ${JSON.stringify(benchmarkCase.expected)}, ` +
            `got ${JSON.stringify(actual)}`,
        );
      }
      decisions += 1;
    }
  }
  return decisions;
}

function percentile(values, fraction) {
  const ordered = values.toSorted((left, right) => left - right);
  const position = (ordered.length - 1) * fraction;
  const lower = Math.floor(position);
  const upper = Math.min(lower + 1, ordered.length - 1);
  return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower);
}

function measure(iterations, warmups, samples, decisionsPerIteration, runIteration) {
  for (let warmup = 0; warmup < warmups; warmup += 1) {
    for (let iteration = 0; iteration < iterations; iteration += 1) runIteration();
  }

  const totals = [];
  for (let sample = 0; sample < samples; sample += 1) {
    const started = process.hrtime.bigint();
    for (let iteration = 0; iteration < iterations; iteration += 1) runIteration();
    totals.push(Number(process.hrtime.bigint() - started));
  }

  const decisions = iterations * decisionsPerIteration;
  const perDecision = totals.map((total) => total / decisions);
  const ordered = perDecision.toSorted((left, right) => left - right);
  const median = percentile(perDecision, 0.5);
  const q1 = percentile(perDecision, 0.25);
  const q3 = percentile(perDecision, 0.75);
  return {
    iterations_per_sample: iterations,
    decisions_per_sample: decisions,
    total_ns: totals,
    ns_per_decision: perDecision,
    distribution_ns_per_decision: {
      min: ordered[0],
      p25: q1,
      median,
      p75: q3,
      max: ordered.at(-1),
      relative_iqr: (q3 - q1) / median,
    },
  };
}

const { values } = parseArgs({
  options: {
    engine: { type: "string" },
    warmups: { type: "string", default: "5" },
    samples: { type: "string", default: "30" },
    "cold-iterations": { type: "string", default: "3" },
    "warm-iterations": { type: "string", default: "50" },
    output: { type: "string" },
    workload: { type: "string" },
  },
});
if (
  !new Set([
    "candidate",
    "candidate-checked",
    "candidate-protobuf",
    "candidate-maps",
    "candidate-functions",
    "candidate-plain",
    "bufbuild",
    "cel-js",
  ]).has(values.engine)
) {
  throw new Error(
    "Pass a candidate engine (`candidate`, `candidate-checked`, `candidate-protobuf`, `candidate-maps`, `candidate-functions`, `candidate-plain`), `bufbuild`, or `cel-js`.",
  );
}
const options = {
  warmups: Number(values.warmups),
  samples: Number(values.samples),
  coldIterations: Number(values["cold-iterations"]),
  warmIterations: Number(values["warm-iterations"]),
};
if (Object.values(options).some((value) => !Number.isInteger(value) || value < 1)) {
  throw new Error("Warmups, samples, and iterations must be positive integers.");
}

const workloads = (await loadWorkloads()).filter(
  (workload) => !values.workload || workload.name === values.workload,
);
if (workloads.length === 0) throw new Error("Unknown workload");
if (values.engine === "candidate-functions") {
  for (const workload of workloads) {
    if (workload.name === "request_authorization") {
      workload.expression =
        'request.method == "GET" && request.path.startsWith("/v1/") && principal.authenticated ' +
        "&& is_allowed(principal.role, resource.owner, principal.id)";
    }
  }
}
const engine = await loadEngine(values.engine);
const programs = workloads.map((workload) => engine.compile(workload.expression));
const decisions = verify(workloads, programs, engine.evaluate);

function coldIteration() {
  for (const workload of workloads) {
    for (const benchmarkCase of workload.cases) {
      const result = engine.evaluate(engine.compile(workload.expression), benchmarkCase.bindings);
      if (result !== benchmarkCase.expected) throw new Error("Decision changed during timing");
    }
  }
}

function warmIteration() {
  for (let workloadIndex = 0; workloadIndex < workloads.length; workloadIndex += 1) {
    for (const benchmarkCase of workloads[workloadIndex].cases) {
      const result = engine.evaluate(programs[workloadIndex], benchmarkCase.bindings);
      if (result !== benchmarkCase.expected) throw new Error("Decision changed during timing");
    }
  }
}

const cpu = cpus()[0];
const results = {
  engine: values.engine,
  engine_version: engine.version,
  runtime: "node",
  environment: {
    node: process.version,
    v8: process.versions.v8,
    platform: `${platform()} ${release()}`,
    architecture: process.arch,
    cpu: cpu?.model ?? "unknown",
    logical_cpus: cpus().length,
  },
  workloads: workloads.map((workload) => ({
    name: workload.name,
    expression: workload.expression,
    cases: workload.cases.length,
  })),
  warmups: options.warmups,
  metrics: {
    cold_compile_and_evaluate: measure(
      options.coldIterations,
      options.warmups,
      options.samples,
      decisions,
      coldIteration,
    ),
    warm_evaluate_reused_program: measure(
      options.warmIterations,
      options.warmups,
      options.samples,
      decisions,
      warmIteration,
    ),
  },
};
const rendered = `${JSON.stringify(results, null, 2)}\n`;
if (values.output === undefined) {
  process.stdout.write(rendered);
} else {
  const output = resolve(values.output);
  await mkdir(dirname(output), { recursive: true });
  await writeFile(output, rendered, "utf8");
  for (const [name, metric] of Object.entries(results.metrics)) {
    const distribution = metric.distribution_ns_per_decision;
    console.log(
      `${name}: median ${distribution.median.toFixed(0)} ns/decision, ` +
        `IQR ${(distribution.relative_iqr * 100).toFixed(1)}%`,
    );
  }
  console.log(`Raw results: ${output}`);
}
