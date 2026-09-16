from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_pinned_network_cases_keep_reference_disagreements_visible(tmp_path: Path, engine: str) -> None:
    manifest = json.loads((ROOT / "testdata" / "manifest.json").read_text())
    entries = [entry for entry in manifest["files"] if entry["name"] == "network_ext"]
    for entry in entries:
        (tmp_path / entry["output"]).write_bytes((ROOT / "testdata" / entry["output"]).read_bytes())
    (tmp_path / "manifest.json").write_text(
        json.dumps({"source": manifest["source"], "summary": {"tests": 69}, "files": entries})
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
        assert process.returncode == 1, process.stdout + process.stderr
        report = json.loads(output.read_text())
        failures = 3 if mode == "full" else 2
        assert report["summary"]["extension"] == {
            "total": 69,
            "passed": 69 - failures,
            "failed": failures,
            "unsupported": 0,
        }
        expected = {
            "network_ext/ipv4/ipv4_equals_ipv6": ("evaluate", "InvalidArgument"),
            "network_ext/ipv4/ipv4_not_equals_ipv6": ("evaluate", "InvalidArgument"),
        }
        if mode == "full":
            expected["network_ext/ip_type/is_ip_cidr_compile_error"] = (
                "compile",
                "TypeMismatch",
            )
        actual = {
            result["id"]: (result["phase"], result["error"])
            for result in report["results"]
            if result["status"] == "failed"
        }
        assert actual == expected


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_network_values_round_trip_through_audit_transport(tmp_path: Path, engine: str) -> None:
    tests = []
    for tag, name, text in (
        ("ipValue", "net.IP", "2001:db8::1"),
        ("cidrValue", "net.CIDR", "10.0.0.17/8"),
    ):
        value = {tag: text}
        tests.append(
            {
                "name": tag,
                "expr": "value",
                "bindings": {"value": {"value": value}},
                "typeEnv": [
                    {
                        "name": "value",
                        "ident": {"type": {"abstractType": {"name": name}}},
                    }
                ],
                "value": value,
            }
        )
    data = json.dumps({"section": [{"name": "transport", "test": tests}]}).encode()
    (tmp_path / "network.json").write_bytes(data)
    (tmp_path / "manifest.json").write_text(
        json.dumps(
            {
                "source": {},
                "summary": {"tests": len(tests)},
                "files": [
                    {
                        "name": "network_transport",
                        "kind": "extension",
                        "output": "network.json",
                        "tests": len(tests),
                        "outputSha256": hashlib.sha256(data).hexdigest(),
                    }
                ],
            }
        )
    )
    for mode in ("full", "evaluation"):
        output = tmp_path / f"{mode}.json"
        result = subprocess.run(
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
        assert result.returncode == 0, result.stdout + result.stderr
        report = json.loads(output.read_text())
        assert report["summary"]["total"] == {
            "total": 2,
            "passed": 2,
            "failed": 0,
            "unsupported": 0,
        }
