from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_pinned_proto_helper_and_encoder_cases_run_through_each_sdk(tmp_path: Path, engine: str) -> None:
    manifest = json.loads((ROOT / "testdata" / "manifest.json").read_text())
    entries = [entry for entry in manifest["files"] if entry["name"] in {"proto2_ext", "encoders_ext"}]
    for entry in entries:
        (tmp_path / entry["output"]).write_bytes((ROOT / "testdata" / entry["output"]).read_bytes())
    (tmp_path / "manifest.json").write_text(
        json.dumps({"source": manifest["source"], "summary": {"tests": 22}, "files": entries})
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
        assert report["summary"]["extension"] == {"total": 22, "passed": 22, "failed": 0, "unsupported": 0}
