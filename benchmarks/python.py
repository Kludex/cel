from __future__ import annotations

import argparse
import importlib
import json
import os
import platform
import statistics
import sys
import time
from collections.abc import Callable
from importlib import metadata
from pathlib import Path
from typing import Any


def load_workloads() -> list[dict[str, Any]]:
    with Path(__file__).with_name("workloads.json").open(encoding="utf-8") as file:
        workloads: list[dict[str, Any]] = json.load(file)
    return workloads


def load_engine(engine: str) -> tuple[Callable[[str], Any], Callable[[Any, dict[str, Any]], Any], str]:
    if engine in (
        "candidate",
        "candidate-checked",
        "candidate-protobuf",
        "candidate-maps",
        "candidate-functions",
        "candidate-plain",
    ):
        try:
            cel = importlib.import_module("cel")
        except ModuleNotFoundError as error:
            raise SystemExit("The candidate is not installed. Build and install bindings/python first.") from error

        names = {name for workload in load_workloads() for case in workload["cases"] for name in case["bindings"]}
        checked_environment = (
            cel.Environment(
                variables={name: cel.CELType("dyn") for name in sorted(names)},
                functions=(
                    cel.Function(
                        "is_allowed",
                        (cel.CELType("string"),) * 3,
                        cel.CELType("bool"),
                        lambda role, owner, identity: role == "admin" or owner == identity,
                    ),
                )
                if engine == "candidate-functions"
                else (),
            )
            if engine in ("candidate-checked", "candidate-protobuf", "candidate-functions")
            else None
        )

        def compile_program(expression: str) -> Any:
            return (
                checked_environment.compile(expression) if checked_environment is not None else cel.Program(expression)
            )

        if engine == "candidate-protobuf":
            json_format = importlib.import_module("google.protobuf.json_format")
            struct_pb2 = importlib.import_module("google.protobuf.struct_pb2")

        def typed_maps(value: Any) -> Any:
            if isinstance(value, dict):
                return cel.CELMap(tuple((key, typed_maps(item)) for key, item in value.items()))
            if isinstance(value, list):
                return [typed_maps(item) for item in value]
            return value

        def evaluate(program: Any, bindings: dict[str, Any]) -> Any:
            if engine == "candidate-maps":
                bindings = {name: typed_maps(value) for name, value in bindings.items()}
            if engine == "candidate-protobuf":
                bindings = {
                    name: cel.Message(
                        "google.protobuf.Struct", json_format.ParseDict(value, struct_pb2.Struct()).SerializeToString()
                    )
                    for name, value in bindings.items()
                }
            if engine == "candidate-plain":
                return program.evaluate(bindings, plain_data=True)
            return program.evaluate(bindings)

        try:
            version = metadata.version("cel-sdk")
        except metadata.PackageNotFoundError:
            version = "source tree"
        return compile_program, evaluate, version

    if engine == "python-cel":
        try:
            version = metadata.version("python-cel")
            rust_cel = importlib.import_module("cel")
        except (ModuleNotFoundError, metadata.PackageNotFoundError) as error:
            raise SystemExit("Install `python-cel==0.1.1` in an isolated environment, without cel-sdk.") from error

        def compile_program(expression: str) -> Any:
            return rust_cel.Program(expression)

        def evaluate(program: Any, bindings: dict[str, Any]) -> Any:
            return program.execute(rust_cel.Context(variables=bindings))

        return compile_program, evaluate, version

    if engine == "cel-rust":
        try:
            version = metadata.version("common-expression-language")
            rust_cel = importlib.import_module("cel")
        except (ModuleNotFoundError, metadata.PackageNotFoundError) as error:
            raise SystemExit(
                "Install `common-expression-language==0.10.0` in an isolated environment, without cel-sdk."
            ) from error

        def compile_program(expression: str) -> Any:
            return rust_cel.compile(expression)

        def evaluate(program: Any, bindings: dict[str, Any]) -> Any:
            return program.execute(bindings)

        return compile_program, evaluate, version

    try:
        celpy = importlib.import_module("celpy")
        evaluation = importlib.import_module("celpy.evaluation")
    except ModuleNotFoundError as error:
        raise SystemExit("Install the optional baseline with `cel-python==0.5.0`.") from error

    environment = celpy.Environment()

    def compile_program(expression: str) -> Any:
        return environment.program(environment.compile(expression))

    def evaluate(program: Any, bindings: dict[str, Any]) -> Any:
        converted = {name: celpy.json_to_cel(value) for name, value in bindings.items()}
        result = program.evaluate(converted)
        if isinstance(result, evaluation.CELEvalError):
            raise RuntimeError(str(result))
        return result

    return compile_program, evaluate, metadata.version("cel-python")


def verify(
    workloads: list[dict[str, Any]],
    programs: list[Any],
    evaluate: Callable[[Any, dict[str, Any]], Any],
) -> int:
    decisions = 0
    for workload, program in zip(workloads, programs, strict=True):
        for case in workload["cases"]:
            actual = evaluate(program, case["bindings"])
            if actual != case["expected"]:
                raise AssertionError(
                    f"{workload['name']}/{case['name']}: expected {case['expected']!r}, got {actual!r}"
                )
            decisions += 1
    return decisions


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def measure(
    iterations: int,
    warmups: int,
    samples: int,
    decisions_per_iteration: int,
    run_iteration: Callable[[], None],
) -> dict[str, Any]:
    for _ in range(warmups):
        for _ in range(iterations):
            run_iteration()

    totals: list[int] = []
    for _ in range(samples):
        started = time.perf_counter_ns()
        for _ in range(iterations):
            run_iteration()
        totals.append(time.perf_counter_ns() - started)

    decision_count = iterations * decisions_per_iteration
    per_decision = [total / decision_count for total in totals]
    median = statistics.median(per_decision)
    q1 = percentile(per_decision, 0.25)
    q3 = percentile(per_decision, 0.75)
    return {
        "iterations_per_sample": iterations,
        "decisions_per_sample": decision_count,
        "total_ns": totals,
        "ns_per_decision": per_decision,
        "distribution_ns_per_decision": {
            "min": min(per_decision),
            "p25": q1,
            "median": median,
            "p75": q3,
            "max": max(per_decision),
            "relative_iqr": (q3 - q1) / median,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark complete CEL request-policy decisions.")
    parser.add_argument(
        "--engine",
        choices=(
            "candidate",
            "candidate-checked",
            "candidate-protobuf",
            "candidate-maps",
            "candidate-functions",
            "candidate-plain",
            "cel-python",
            "python-cel",
            "cel-rust",
        ),
        required=True,
    )
    parser.add_argument("--warmups", type=int, default=5)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--cold-iterations", type=int, default=3)
    parser.add_argument("--warm-iterations", type=int, default=50)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--workload", help="Run one complete named workload")
    args = parser.parse_args()
    if min(args.warmups, args.samples, args.cold_iterations, args.warm_iterations) < 1:
        parser.error("warmups, samples, and iterations must be positive")

    workloads = load_workloads()
    if args.engine == "candidate-functions":
        for workload in workloads:
            if workload["name"] == "request_authorization":
                workload["expression"] = (
                    'request.method == "GET" && request.path.startsWith("/v1/") && principal.authenticated '
                    "&& is_allowed(principal.role, resource.owner, principal.id)"
                )
    if args.workload:
        workloads = [workload for workload in workloads if workload["name"] == args.workload]
        if not workloads:
            parser.error("unknown workload")
    compile_program, evaluate, version = load_engine(args.engine)
    programs = [compile_program(workload["expression"]) for workload in workloads]
    decisions = verify(workloads, programs, evaluate)

    def cold_iteration() -> None:
        for workload in workloads:
            for case in workload["cases"]:
                if evaluate(compile_program(workload["expression"]), case["bindings"]) != case["expected"]:
                    raise AssertionError("Decision changed during timing")

    def warm_iteration() -> None:
        for workload, program in zip(workloads, programs, strict=True):
            for case in workload["cases"]:
                if evaluate(program, case["bindings"]) != case["expected"]:
                    raise AssertionError("Decision changed during timing")

    results = {
        "engine": args.engine,
        "engine_version": version,
        "runtime": "python",
        "environment": {
            "python": platform.python_version(),
            "implementation": platform.python_implementation(),
            "executable": sys.executable,
            "platform": platform.platform(),
            "machine": platform.machine(),
            "logical_cpus": os.cpu_count(),
        },
        "workloads": [
            {"name": workload["name"], "expression": workload["expression"], "cases": len(workload["cases"])}
            for workload in workloads
        ],
        "warmups": args.warmups,
        "metrics": {
            "cold_compile_and_evaluate": measure(
                args.cold_iterations, args.warmups, args.samples, decisions, cold_iteration
            ),
            "warm_evaluate_reused_program": measure(
                args.warm_iterations, args.warmups, args.samples, decisions, warm_iteration
            ),
        },
    }
    rendered = json.dumps(results, indent=2) + "\n"
    if args.output is None:
        sys.stdout.write(rendered)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
        for name, metric in results["metrics"].items():
            distribution = metric["distribution_ns_per_decision"]
            sys.stdout.write(
                f"{name}: median {distribution['median']:.0f} ns/decision, IQR {distribution['relative_iqr']:.1%}\n"
            )
        sys.stdout.write(f"Raw results: {args.output}\n")


if __name__ == "__main__":
    main()
