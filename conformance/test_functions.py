from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_upstream_function_declarations_and_generic_results_are_checked(tmp_path: Path, engine: str) -> None:
    original = json.loads((ROOT / "testdata" / "type_deduction.json").read_text())
    tests = [
        case
        for section in original["section"]
        for case in section["test"]
        if any("function" in declaration for declaration in case.get("typeEnv", []))
    ]
    assert len(tests) == 5
    data = json.dumps({"section": [{"name": "functions", "test": tests}]}).encode()
    (tmp_path / "functions.json").write_bytes(data)
    (tmp_path / "manifest.json").write_text(
        json.dumps(
            {
                "source": {"fixture": "pinned type_deduction function cases"},
                "summary": {"tests": len(tests)},
                "files": [
                    {
                        "name": "function_types",
                        "kind": "core",
                        "output": "functions.json",
                        "tests": len(tests),
                        "outputSha256": hashlib.sha256(data).hexdigest(),
                    }
                ],
            }
        )
    )
    report = tmp_path / "report.json"
    process = subprocess.run(
        [
            sys.executable,
            str(ROOT / "run.py"),
            "--engine",
            engine,
            "--mode",
            "full",
            "--corpus",
            str(tmp_path),
            "--report",
            str(report),
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert process.returncode == 0, process.stdout + process.stderr
    result = json.loads(report.read_text())
    assert result["summary"]["total"] == {"total": 5, "passed": 5, "failed": 0, "unsupported": 0}
    assert result["successfullyChecked"] == 5
