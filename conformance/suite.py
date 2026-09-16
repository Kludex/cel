from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

from type_codec import unsupported_type


@dataclass(frozen=True)
class Case:
    identifier: str
    kind: str
    test: dict[str, Any]
    reasons: list[str]
    strong_enums: bool = False


def load_json(path: Path) -> dict[str, Any]:
    return cast(dict[str, Any], json.loads(path.read_text(encoding="utf-8")))


def load_cases(corpus: Path, policy: dict[str, Any], mode: str) -> tuple[dict[str, Any], list[Case]]:
    manifest = load_json(corpus / "manifest.json")
    cases: list[Case] = []
    occurrences: dict[str, int] = {}
    for entry in manifest["files"]:
        data = (corpus / entry["output"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != entry["outputSha256"]:
            raise RuntimeError(f"corpus checksum mismatch: {entry['output']}")
        test_file = json.loads(data)
        seen = 0
        for section in test_file.get("section", []):
            for test in section.get("test", []):
                seen += 1
                base = f"{entry['name']}/{section['name']}/{test['name']}"
                occurrences[base] = occurrences.get(base, 0) + 1
                identifier = base if occurrences[base] == 1 else f"{base}#{occurrences[base]}"
                reasons = set(unsupported_reasons(entry["name"], test, policy))
                if mode == "evaluation" and test.get("checkOnly"):
                    reasons.add("check_only")
                strong_enums = entry["name"] == "enums" and section["name"] in ("strong_proto2", "strong_proto3")
                cases.append(Case(identifier, entry["kind"], test, sorted(reasons), strong_enums))
        if seen != entry["tests"]:
            raise RuntimeError(f"case count mismatch: {entry['output']}")
    if len(cases) != manifest["summary"]["tests"]:
        raise RuntimeError("corpus total does not match manifest")
    return manifest, cases


def unsupported_reasons(file_name: str, test: dict[str, Any], policy: dict[str, Any]) -> list[str]:
    reasons = set(policy["fileReasons"].get(file_name, []))
    for field, reason in policy["fieldReasons"].items():
        if test.get(field):
            reasons.add(reason)
    for fragment, reason in policy["expressionReasons"].items():
        if fragment in test["expr"]:
            reasons.add(reason)
    for field, reason in policy["matcherReasons"].items():
        if field in test:
            reasons.add(reason)
    for declaration in test.get("typeEnv", []):
        if "function" in declaration:
            for overload in declaration["function"].get("overloads", []):
                for type_description in [*overload.get("params", []), overload.get("resultType", {})]:
                    reason = unsupported_type(type_description)
                    if reason:
                        reasons.add(reason)
        else:
            reason = unsupported_type(declaration.get("ident", {}).get("type", {}))
            if reason:
                reasons.add(reason)
    if "typedResult" in test:
        reason = unsupported_type(test["typedResult"].get("deducedType", {}))
        if reason:
            reasons.add(reason)
    for binding in test.get("bindings", {}).values():
        for field, reason in policy["exprValueReasons"].items():
            if field in binding:
                reasons.add(reason)
        if "value" in binding:
            reasons.update(value_reasons(binding["value"], policy))
    if "value" in test:
        reasons.update(value_reasons(test["value"], policy))
    if "typedResult" in test:
        reasons.update(value_reasons(test["typedResult"].get("result", {}), policy))
    return sorted(reasons)


def value_reasons(value: Any, policy: dict[str, Any]) -> set[str]:
    reasons: set[str] = set()
    if not isinstance(value, dict):
        return reasons
    for key, reason in policy["valueReasons"].items():
        if key in value:
            reasons.add(reason)
    for item in value.values():
        if isinstance(item, dict):
            reasons.update(value_reasons(item, policy))
        elif isinstance(item, list):
            for child in item:
                reasons.update(value_reasons(child, policy))
    return reasons


def summarize(
    manifest: dict[str, Any], cases: list[Case], results: list[dict[str, Any]], engine: str, mode: str
) -> dict[str, Any]:
    summary = {
        name: dict.fromkeys(("total", "passed", "failed", "unsupported"), 0) for name in ("total", "core", "extension")
    }
    gaps: dict[str, int] = {}
    for result in results:
        for name in ("total", result["kind"]):
            summary[name]["total"] += 1
            summary[name][result["status"]] += 1
        for reason in result.get("reasons", []):
            gaps[reason] = gaps.get(reason, 0) + 1
    return {
        "schemaVersion": 1,
        "implementation": f"{engine}-public-api",
        "mode": mode,
        "successfullyChecked": sum("checkedType" in result for result in results),
        "omittedChecks": sum(
            not case.test.get("disableCheck", False) or "typedResult" in case.test for case in cases if not case.reasons
        )
        if mode == "evaluation"
        else 0,
        "fullConformance": mode == "full" and summary["total"]["failed"] == 0 and summary["total"]["unsupported"] == 0,
        "source": manifest["source"],
        "summary": summary,
        "sourceGaps": dict(sorted(gaps.items())),
        "results": results,
    }
