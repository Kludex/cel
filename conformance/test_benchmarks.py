from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
from typing_extensions import TypedDict


class Case(TypedDict):
    name: str
    bindings: dict[str, int]
    expected: bool


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("field", ["name", "bindings", "expected"])
def test_paired_policy_benchmarks_reject_changed_decisions(tmp_path: Path, field: str) -> None:
    case: Case = {"name": "allow", "bindings": {}, "expected": True}
    before = [{"name": "policy", "expression": "true", "cases": [case.copy()]}]
    if field == "name":
        case["name"] = "different"
    elif field == "bindings":
        case["bindings"] = {"extra": 1}
    else:
        case["expected"] = False
    after = [{"name": "policy", "expression": "false", "cases": [case]}]
    first, second = tmp_path / "before.json", tmp_path / "after.json"
    first.write_text(json.dumps(before))
    second.write_text(json.dumps(after))
    process = subprocess.run(
        [
            "node",
            str(ROOT / "benchmarks/profiling/paired.mjs"),
            "--before",
            str(tmp_path / "missing-before.js"),
            "--after",
            str(tmp_path / "missing-after.js"),
            "--workloads",
            str(first),
            "--after-workloads",
            str(second),
            "--iterations",
            "1",
        ],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert process.returncode != 0
    assert "Paired policies must use identical named decisions, inputs, and expected results" in process.stderr
    assert "ERR_MODULE_NOT_FOUND" not in process.stderr


def test_native_competitor_engine_reports_a_clear_installation_error(
    tmp_path: Path,
) -> None:
    process = subprocess.run(
        [
            str(ROOT / "bindings/python/.venv/bin/python"),
            str(ROOT / "benchmarks/python.py"),
            "--engine",
            "cel-rust",
            "--output",
            str(tmp_path / "out.json"),
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert process.returncode != 0
    assert "common-expression-language==0.10.0" in process.stderr
    assert not (tmp_path / "out.json").exists()
