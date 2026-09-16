from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, cast

from cel import CompileError, Environment, EvaluationError, Function
from messages import DESCRIPTORS, normalize, transport
from suite import Case, load_cases, load_json, summarize
from type_codec import decode_type, encode_type
from typing_extensions import Literal, NotRequired, TypedDict
from values import UnsupportedValueError, decode_value, encode_value, values_equal

ROOT = Path(__file__).resolve().parent


class Outcome(TypedDict):
    id: str
    outcome: Literal["value", "checked", "compile_error", "eval_error", "input_error", "unsupported"]
    value: NotRequired[dict[str, Any]]
    error: NotRequired[str]
    checked_type: NotRequired[dict[str, Any]]


def execute_python(case: Case, mode: str) -> Outcome:
    checked = mode == "full" and (not case.test.get("disableCheck", False) or "typedResult" in case.test)
    try:
        environment = Environment(
            descriptors=DESCRIPTORS,
            strong_enums=case.strong_enums,
            container=case.test.get("container", ""),
            variables={
                declaration["name"]: decode_type(declaration["ident"]["type"])
                for declaration in case.test.get("typeEnv", [])
                if "ident" in declaration
            },
            functions=tuple(
                Function(
                    declaration["name"],
                    tuple(decode_type(t) for t in overload.get("params", [])),
                    decode_type(overload["resultType"]),
                    overload_id=overload.get("overloadId", ""),
                    member=overload.get("isInstanceFunction", False),
                )
                for declaration in case.test.get("typeEnv", [])
                for overload in declaration.get("function", {}).get("overloads", [])
            ),
        )
        program = environment.compile(case.test["expr"], check=checked)
    except CompileError as exc:
        return {"id": case.identifier, "outcome": "compile_error", "error": str(exc)}
    metadata = {"checked_type": encode_type(program.result_type)} if program.result_type is not None else {}
    if case.test.get("checkOnly"):
        return cast(Outcome, {"id": case.identifier, "outcome": "checked", **metadata})
    try:
        bindings = {name: decode_value(binding["value"]) for name, binding in case.test.get("bindings", {}).items()}
        actual = program(bindings)
    except UnsupportedValueError as exc:
        return {"id": case.identifier, "outcome": "unsupported", "error": str(exc)}
    except EvaluationError as exc:
        return cast(Outcome, {"id": case.identifier, "outcome": "eval_error", "error": str(exc), **metadata})
    except (TypeError, ValueError, OverflowError) as exc:
        return {"id": case.identifier, "outcome": "input_error", "error": str(exc)}
    return cast(Outcome, {"id": case.identifier, "outcome": "value", "value": encode_value(actual), **metadata})


def compare(case: Case, outcome: Outcome, mode: str) -> dict[str, Any]:
    base: dict[str, Any] = {"id": case.identifier, "kind": case.kind, "strongEnums": case.strong_enums}
    if outcome["id"] != case.identifier:
        raise RuntimeError("Adapter returned a mismatched case ID")
    expected_error = "evalError" in case.test or "anyEvalErrors" in case.test
    if outcome["outcome"] == "unsupported":
        return base | {"status": "unsupported", "reasons": ["binding_representation"], "error": outcome.get("error")}
    if outcome["outcome"] in ("compile_error", "input_error"):
        return base | {
            "status": "failed",
            "phase": "compile" if outcome["outcome"] == "compile_error" else "inputs",
            "error": outcome.get("error"),
        }
    checked = mode == "full" and (not case.test.get("disableCheck", False) or "typedResult" in case.test)
    if checked:
        expected_type = case.test.get("typedResult", {}).get("deducedType")
        if "checked_type" not in outcome or (
            expected_type is not None and decode_type(outcome["checked_type"]) != decode_type(expected_type)
        ):
            return base | {
                "status": "failed",
                "phase": "check",
                "expected": expected_type,
                "actual": outcome.get("checked_type"),
            }
    if checked:
        base["checkedType"] = outcome["checked_type"]
    if outcome["outcome"] == "checked":
        return base | {"status": "passed", "outcome": "checked"}
    if outcome["outcome"] == "eval_error":
        if expected_error:
            return base | {"status": "passed", "outcome": "eval_error"}
        return base | {"status": "failed", "phase": "evaluate", "error": outcome.get("error")}
    if outcome["outcome"] != "value" or "value" not in outcome:
        raise RuntimeError("Adapter returned an invalid outcome")
    expected = case.test.get("typedResult", {}).get("result", case.test.get("value", {"boolValue": True}))
    if not expected_error and values_equal(outcome["value"], expected):
        return base | {"status": "passed", "outcome": "value"}
    return base | {
        "status": "failed",
        "phase": "compare",
        "expected": "eval_error" if expected_error else expected,
        "actual": outcome["value"],
    }


def run(corpus: Path, engine: str, mode: str) -> dict[str, Any]:
    policy = load_json(ROOT / "unsupported.json")
    manifest, cases = load_cases(corpus, policy, mode)
    supported = [case for case in cases if not case.reasons]
    if engine == "python":
        outcomes = [execute_python(case, mode) for case in supported]
    else:
        requests = [
            {
                "id": case.identifier,
                "expr": case.test["expr"],
                "bindings": {name: binding["value"] for name, binding in case.test.get("bindings", {}).items()},
                "container": case.test.get("container", ""),
                "strongEnums": case.strong_enums,
                "variables": {
                    declaration["name"]: declaration["ident"]["type"]
                    for declaration in case.test.get("typeEnv", [])
                    if "ident" in declaration
                },
                "functions": [
                    {
                        "name": declaration["name"],
                        "overloadId": overload.get("overloadId", ""),
                        "params": overload.get("params", []),
                        "resultType": overload["resultType"],
                        "member": overload.get("isInstanceFunction", False),
                    }
                    for declaration in case.test.get("typeEnv", [])
                    for overload in declaration.get("function", {}).get("overloads", [])
                ],
                "check": mode == "full" and (not case.test.get("disableCheck", False) or "typedResult" in case.test),
                "checkOnly": case.test.get("checkOnly", False),
            }
            for case in supported
        ]
        command = ["node", str(ROOT / "node.mjs")]
        if engine == "zig":
            adapter = ROOT.parent / "zig-out" / "bin" / "cel-conformance"
            if not adapter.is_file():
                raise RuntimeError("Build the Zig adapter with zig build conformance -Dconformance=true")
            command = [str(adapter)]
        payload = json.dumps(transport(requests))
        if dump := os.environ.get("CEL_CONFORMANCE_DUMP"):
            Path(dump).write_text(payload, encoding="utf-8")
        process = subprocess.run(
            command,
            input=payload,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if process.returncode:
            raise RuntimeError(f"{engine} adapter failed: {process.stderr}")
        outcomes = cast(list[Outcome], normalize(json.loads(process.stdout)))
    if len(outcomes) != len(supported):
        raise RuntimeError("Adapter returned an incorrect case count")
    by_id = {case.identifier: compare(case, outcome, mode) for case, outcome in zip(supported, outcomes, strict=True)}
    results = [
        by_id[case.identifier]
        if not case.reasons
        else {"id": case.identifier, "kind": case.kind, "status": "unsupported", "reasons": case.reasons}
        for case in cases
    ]
    return summarize(manifest, cases, results, engine, mode)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the imported CEL simple conformance corpus")
    parser.add_argument("--corpus", type=Path, default=ROOT / "testdata")
    parser.add_argument("--engine", choices=("python", "node", "zig"), default="python")
    parser.add_argument("--mode", choices=("full", "evaluation"), default="full")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = run(args.corpus, args.engine, args.mode)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for name, counts in report["summary"].items():
        sys.stdout.write(f"{name}: " + " ".join(f"{key}={value}" for key, value in counts.items()) + "\n")
    if args.mode == "full":
        return int(not report["fullConformance"])
    return int(report["summary"]["total"]["failed"] != 0)


if __name__ == "__main__":
    raise SystemExit(main())
