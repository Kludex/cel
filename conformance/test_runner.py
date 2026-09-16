from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_audit_preserves_types_phases_and_map_key_distinctions(tmp_path: Path, engine: str) -> None:
    tests: list[dict[str, Any]] = [
        {"name": "uint", "expr": "1u", "value": {"uint64Value": "1"}},
        {"name": "null", "expr": "null", "value": {"nullValue": "NULL_VALUE"}},
        {"name": "nan", "expr": "0.0 / 0.0", "value": {"doubleValue": "NaN"}},
        {"name": "type", "expr": "type(1)", "value": {"typeValue": "int"}},
        {
            "name": "null_input",
            "expr": "x",
            "bindings": {"x": {"value": {"nullValue": "NULL_VALUE"}}},
            "value": {"nullValue": "NULL_VALUE"},
        },
        {
            "name": "syntax_before_input",
            "expr": "1 +",
            "evalError": {},
            "bindings": {
                "x": {"value": {"mapValue": {"entries": [{"key": {"int64Value": "1"}, "value": {"boolValue": True}}]}}}
            },
        },
        {"name": "eval_error", "expr": "1 / 0", "evalError": {}},
        {"name": "compile_error", "expr": "1 +", "evalError": {}},
        {"name": "wrong_type", "expr": "true", "value": {"int64Value": "1"}},
        {
            "name": "distinct_keys",
            "expr": "{true: 'same'}",
            "value": {
                "mapValue": {
                    "entries": [
                        {"key": {"boolValue": True}, "value": {"stringValue": "same"}},
                        {"key": {"int64Value": "1"}, "value": {"stringValue": "same"}},
                    ]
                }
            },
        },
    ]
    for case in tests:
        case["disableCheck"] = True
    corpus = json.dumps({"name": "audit", "section": [{"name": "checks", "test": tests}]}).encode()
    (tmp_path / "audit.json").write_bytes(corpus)
    manifest = {
        "source": {"purpose": "audit self-test"},
        "summary": {"tests": len(tests)},
        "files": [
            {
                "name": "audit",
                "kind": "core",
                "output": "audit.json",
                "outputSha256": hashlib.sha256(corpus).hexdigest(),
                "tests": len(tests),
            }
        ],
    }
    (tmp_path / "manifest.json").write_text(json.dumps(manifest))
    report_path = tmp_path / "report.json"
    command = [
        sys.executable,
        str(ROOT / "run.py"),
        "--corpus",
        str(tmp_path),
        "--engine",
        engine,
        "--report",
        str(report_path),
    ]
    process = subprocess.run(command, capture_output=True, text=True, timeout=30)
    assert process.returncode == 1, process.stderr
    report = json.loads(report_path.read_text())
    assert report["fullConformance"] is False
    assert report["summary"]["total"] == {"total": 10, "passed": 6, "failed": 4, "unsupported": 0}
    results = {entry["id"].split("/")[-1]: entry for entry in report["results"]}
    assert results["compile_error"]["phase"] == "compile"
    assert results["syntax_before_input"]["phase"] == "compile"
    assert results["wrong_type"]["phase"] == "compare"
    assert results["distinct_keys"]["phase"] == "compare"

    (tmp_path / "audit.json").write_bytes(corpus + b" ")
    report_path.unlink()
    process = subprocess.run(command, capture_output=True, text=True, timeout=30)
    assert process.returncode != 0
    assert "checksum mismatch" in process.stderr
    assert not report_path.exists()


def test_report_comparison_accepts_baselines_and_rejects_regressions(tmp_path: Path) -> None:
    baseline = ROOT / "report.json"
    matching = subprocess.run(
        [sys.executable, str(ROOT / "compare_reports.py"), str(ROOT / "report-node.json"), str(baseline)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert matching.returncode == 0, matching.stdout + matching.stderr
    report = json.loads(baseline.read_text())
    report["results"][0]["status"] = "failed"
    report["summary"]["total"]["passed"] -= 1
    regressed = tmp_path / "regressed.json"
    regressed.write_text(json.dumps(report))
    failing = subprocess.run(
        [sys.executable, str(ROOT / "compare_reports.py"), str(regressed), str(baseline)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert failing.returncode == 1
    assert "summary:" in failing.stdout and report["results"][0]["id"] in failing.stdout
    usage = subprocess.run([sys.executable, str(ROOT / "compare_reports.py")], capture_output=True, timeout=60)
    assert usage.returncode == 2
