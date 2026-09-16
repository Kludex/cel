from __future__ import annotations

import hashlib
import json
import platform
import sys
from importlib import metadata
from pathlib import Path
from typing import Any

import cel


def failure(error: Exception) -> dict[str, str]:
    return {"type": type(error).__name__, "message": str(error)}


def main() -> None:
    workloads_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    workloads: list[dict[str, Any]] = json.loads(workloads_path.read_text(encoding="utf-8"))
    results: list[dict[str, Any]] = []

    for workload in workloads:
        result: dict[str, Any] = {"name": workload["name"], "expression": workload["expression"], "cases": []}
        try:
            program = cel.Program(workload["expression"])
        except Exception as error:
            result["compile_error"] = failure(error)
            result["cases"] = [
                {"name": case["name"], "expected": case["expected"], "outcome": "not_run_compile_error"}
                for case in workload["cases"]
            ]
            results.append(result)
            continue

        for case in workload["cases"]:
            case_result: dict[str, Any] = {"name": case["name"], "expected": case["expected"]}
            try:
                actual = program.execute(cel.Context(variables=case["bindings"]))
                case_result.update(
                    outcome="passed" if actual == case["expected"] else "mismatched",
                    actual=actual,
                    actual_type=type(actual).__name__,
                )
            except Exception as error:
                case_result.update(outcome="evaluation_error", error=failure(error))
            result["cases"].append(case_result)
        results.append(result)

    outcomes = [case["outcome"] for result in results for case in result["cases"]]
    output = {
        "summary": {
            "workloads": len(results),
            "cases": len(outcomes),
            "compiled_workloads": sum("compile_error" not in result for result in results),
            "compile_failed_workloads": sum("compile_error" in result for result in results),
            "passed_cases": outcomes.count("passed"),
            "mismatched_cases": outcomes.count("mismatched"),
            "evaluation_error_cases": outcomes.count("evaluation_error"),
            "not_run_compile_error_cases": outcomes.count("not_run_compile_error"),
        },
        "package": {"name": "python-cel", "version": metadata.version("python-cel")},
        "api": {
            "program_methods": [name for name in dir(cel.Program("true")) if not name.startswith("_")],
            "documented_execution_method": "Program.execute(Context)",
        },
        "environment": {
            "python": platform.python_version(),
            "implementation": platform.python_implementation(),
            "platform": platform.platform(),
            "machine": platform.machine(),
        },
        "workloads_sha256": hashlib.sha256(workloads_path.read_bytes()).hexdigest(),
        "workloads": results,
    }
    output_path.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
