from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_full_mode_runs_checking_and_validates_deduced_types(tmp_path: Path, engine: str) -> None:
    tests = [
        {
            "name": "required",
            "expr": "x + 1",
            "value": {"int64Value": "3"},
            "typeEnv": [{"name": "x", "ident": {"type": {"primitive": "INT64"}}}],
            "bindings": {"x": {"value": {"int64Value": "2"}}},
        },
        {"name": "invalid_dead_branch", "expr": "false && 1", "value": {"boolValue": False}},
        {
            "name": "check_only",
            "expr": "1 + 1",
            "checkOnly": True,
            "typedResult": {"deducedType": {"primitive": "INT64"}},
        },
        {
            "name": "wrong_deduced_type",
            "expr": "[]",
            "checkOnly": True,
            "typedResult": {"deducedType": {"primitive": "BOOL"}},
        },
    ]
    data = json.dumps({"section": [{"name": "checking", "test": tests}]}).encode()
    (tmp_path / "checking.json").write_bytes(data)
    (tmp_path / "manifest.json").write_text(
        json.dumps(
            {
                "source": {},
                "summary": {"tests": 4},
                "files": [
                    {
                        "name": "checking",
                        "kind": "core",
                        "output": "checking.json",
                        "outputSha256": hashlib.sha256(data).hexdigest(),
                        "tests": 4,
                    }
                ],
            }
        )
    )
    for mode in ("full", "evaluation"):
        output = tmp_path / f"{mode}.json"
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
                str(output),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert process.returncode == (1 if mode == "full" else 0), process.stderr
        report = json.loads(output.read_text())
        assert report["fullConformance"] is False
        assert report["mode"] == mode
        assert report["omittedChecks"] == (2 if mode == "evaluation" else 0)
        results = report["results"]
        assert results[0]["status"] == "passed"
        if mode == "full":
            assert results[1]["status"] == "failed"
            assert results[1]["error"] == "TypeMismatch"
            assert results[2]["outcome"] == "checked"
            assert results[3]["phase"] == "check"
        else:
            assert results[1]["status"] == "passed"
            assert results[2]["status"] == "unsupported"
            assert results[3]["status"] == "unsupported"
