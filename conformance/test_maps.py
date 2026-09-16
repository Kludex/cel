from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent


@pytest.mark.parametrize("engine", ["python", "node", "zig"])
def test_audit_preserves_mixed_map_keys_in_inputs_and_outputs(tmp_path: Path, engine: str) -> None:
    value = {
        "mapValue": {
            "entries": [
                {"key": {"boolValue": True}, "value": {"stringValue": "boolean"}},
                {"key": {"int64Value": "1"}, "value": {"stringValue": "integer"}},
                {"key": {"uint64Value": "18446744073709551615"}, "value": {"stringValue": "maximum"}},
                {"key": {"int64Value": "-1"}, "value": {"stringValue": "negative"}},
            ]
        }
    }
    declaration = {
        "name": "m",
        "ident": {
            "type": {
                "mapType": {
                    "keyType": {"dyn": {}},
                    "valueType": {"dyn": {}},
                }
            }
        },
    }
    tests = [
        {
            "name": "round_trip",
            "expr": "m",
            "bindings": {"m": {"value": value}},
            "typeEnv": [declaration],
            "value": value,
        },
        {
            "name": "read_typed_keys",
            "expr": "m[true] == 'boolean' && m[1u] == 'integer' && m[-1] == 'negative'",
            "bindings": {"m": {"value": value}},
            "typeEnv": [declaration],
            "value": {"boolValue": True},
        },
        {
            "name": "literal",
            "expr": "{true:'boolean', 1:'integer', 18446744073709551615u:'maximum', -1:'negative'}",
            "value": value,
        },
    ]
    data = json.dumps({"section": [{"name": "maps", "test": tests}]}).encode()
    (tmp_path / "maps.json").write_bytes(data)
    (tmp_path / "manifest.json").write_text(
        json.dumps(
            {
                "source": {},
                "summary": {"tests": len(tests)},
                "files": [
                    {
                        "name": "typed_maps",
                        "kind": "core",
                        "output": "maps.json",
                        "tests": len(tests),
                        "outputSha256": hashlib.sha256(data).hexdigest(),
                    }
                ],
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
        assert report["summary"]["total"] == {"total": 3, "passed": 3, "failed": 0, "unsupported": 0}
