from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_optional_transport_preserves_absence_and_present_null(tmp_path: Path, engine: str) -> None:
    values = [
        {"optionalValue": {}},
        {"optionalValue": {"value": {"nullValue": None}}},
        {"optionalValue": {"value": {"optionalValue": {}}}},
    ]
    tests = [
        {
            "name": str(index),
            "expr": "value",
            "disableCheck": True,
            "bindings": {"value": {"value": value}},
            "value": value,
        }
        for index, value in enumerate(values)
    ]
    data = json.dumps({"section": [{"name": "transport", "test": tests}]}).encode()
    (tmp_path / "values.json").write_bytes(data)
    (tmp_path / "manifest.json").write_text(
        json.dumps(
            {
                "source": {},
                "summary": {"tests": len(tests)},
                "files": [
                    {
                        "name": "optional_transport",
                        "kind": "core",
                        "output": "values.json",
                        "tests": len(tests),
                        "outputSha256": hashlib.sha256(data).hexdigest(),
                    }
                ],
            }
        )
    )
    report = tmp_path / "report.json"
    process = subprocess.run(
        [sys.executable, str(ROOT / "run.py"), "--engine", engine, "--corpus", str(tmp_path), "--report", str(report)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert process.returncode == 0, process.stdout + process.stderr
    assert json.loads(report.read_text())["summary"]["total"] == {
        "total": 3,
        "passed": 3,
        "failed": 0,
        "unsupported": 0,
    }


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_complete_pinned_optional_file_runs_in_both_modes(tmp_path: Path, engine: str) -> None:
    manifest = json.loads((ROOT / "testdata" / "manifest.json").read_text())
    entry = next(item for item in manifest["files"] if item["name"] == "optionals")
    (tmp_path / entry["output"]).write_bytes((ROOT / "testdata" / entry["output"]).read_bytes())
    (tmp_path / "manifest.json").write_text(
        json.dumps(
            {
                "source": manifest["source"],
                "summary": {"tests": entry["tests"]},
                "files": [entry],
            }
        )
    )
    for mode in ("full", "evaluation"):
        report_path = tmp_path / f"{mode}.json"
        process = subprocess.run(
            [
                sys.executable,
                str(ROOT / "run.py"),
                "--corpus",
                str(tmp_path),
                "--engine",
                engine,
                "--mode",
                mode,
                "--report",
                str(report_path),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert process.returncode == 0, process.stdout + process.stderr
        report = json.loads(report_path.read_text())
        assert report["summary"]["total"] == {
            "total": entry["tests"],
            "passed": entry["tests"],
            "failed": 0,
            "unsupported": 0,
        }
