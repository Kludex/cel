"""Fail when an audit report differs from its committed baseline in anything but the recorded implementation label.

Usage: compare_reports.py ACTUAL.json BASELINE.json
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def differences(actual: dict[str, Any], baseline: dict[str, Any]) -> list[str]:
    compared = ("summary", "successfullyChecked", "mode", "fullConformance")
    problems = [f"{key}: {actual[key]!r} != {baseline[key]!r}" for key in compared if actual[key] != baseline[key]]
    expected = {case["id"]: case for case in baseline["results"]}
    for case in actual["results"]:
        want = expected.get(case["id"])
        if want is None:
            problems.append(f"{case['id']}: not in baseline")
        elif case != want:
            problems.append(f"{case['id']}: {case} != {want}")
    missing = set(expected) - {case["id"] for case in actual["results"]}
    problems.extend(f"{identifier}: missing from actual report" for identifier in sorted(missing))
    return problems


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    actual = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    baseline = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    problems = differences(actual, baseline)
    for problem in problems[:50]:
        print(problem)
    if problems:
        print(f"{len(problems)} difference(s) from {sys.argv[2]}")
        return 1
    print(f"matches {sys.argv[2]}: {actual['summary']['total']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
