from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_audit_selects_strong_enum_mode_without_changing_legacy_cases(tmp_path: Path, engine: str) -> None:
    manifest = json.loads((ROOT / "testdata" / "manifest.json").read_text())
    entry = next(item for item in manifest["files"] if item["name"] == "enums")
    (tmp_path / entry["output"]).write_bytes((ROOT / "testdata" / entry["output"]).read_bytes())
    (tmp_path / "manifest.json").write_text(
        json.dumps({"source": manifest["source"], "summary": {"tests": entry["tests"]}, "files": [entry]})
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
        assert process.returncode == 0, process.stdout + process.stderr
        report = json.loads(output.read_text())
        assert report["summary"]["total"] == {
            "total": entry["tests"],
            "passed": entry["tests"],
            "failed": 0,
            "unsupported": 0,
        }
        for result in report["results"]:
            assert result["strongEnums"] is ("/strong_" in result["id"])
