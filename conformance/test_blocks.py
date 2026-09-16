from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_pinned_block_extension_runs_through_each_sdk(tmp_path: Path, engine: str) -> None:
    manifest = json.loads((ROOT / "testdata" / "manifest.json").read_text())
    entry = next(item for item in manifest["files"] if item["name"] == "block_ext")
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
                "--engine",
                engine,
                "--mode",
                mode,
                "--corpus",
                str(tmp_path),
                "--report",
                str(output),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert process.returncode == 0, process.stdout + process.stderr
        report = json.loads(output.read_text())
        assert report["summary"]["extension"] == {"total": 37, "passed": 37, "failed": 0, "unsupported": 0}
