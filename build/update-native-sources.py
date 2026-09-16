from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory


def main() -> None:
    parser = argparse.ArgumentParser(description="Regenerate the pinned RE2/protobuf/Abseil translation-unit list")
    parser.add_argument("--re2", required=True, type=Path)
    parser.add_argument("--abseil", required=True, type=Path)
    parser.add_argument("--protobuf", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("native_sources.zon"))
    args = parser.parse_args()
    with TemporaryDirectory() as directory:
        temporary = Path(directory)
        (temporary / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.22)\n"
            "project(cel_native C CXX)\n"
            "set(CMAKE_CXX_STANDARD 17)\n"
            "set(CMAKE_EXPORT_COMPILE_COMMANDS ON)\n"
            'set(BUILD_TESTING OFF CACHE BOOL "" FORCE)\n'
            'set(ABSL_BUILD_TESTING OFF CACHE BOOL "" FORCE)\n'
            'set(RE2_BUILD_TESTING OFF CACHE BOOL "" FORCE)\n'
            'set(RE2_INSTALL OFF CACHE BOOL "" FORCE)\n'
            'add_subdirectory("${ABSEIL_SOURCE}" abseil)\n'
            'add_subdirectory("${RE2_SOURCE}" re2)\n'
            'set(protobuf_BUILD_TESTS OFF CACHE BOOL "" FORCE)\n'
            'set(protobuf_BUILD_PROTOC_BINARIES OFF CACHE BOOL "" FORCE)\n'
            'set(protobuf_BUILD_LIBUPB OFF CACHE BOOL "" FORCE)\n'
            'set(protobuf_INSTALL OFF CACHE BOOL "" FORCE)\n'
            'set(protobuf_WITH_ZLIB OFF CACHE BOOL "" FORCE)\n'
            'add_subdirectory("${PROTOBUF_SOURCE}" protobuf)\n'
        )
        subprocess.run(
            [
                "cmake",
                "-S",
                directory,
                "-B",
                str(temporary / "build"),
                f"--graphviz={temporary / 'targets.dot'}",
                "-DCMAKE_BUILD_TYPE=Release",
                f"-DRE2_SOURCE={args.re2.resolve()}",
                f"-DABSEIL_SOURCE={args.abseil.resolve()}",
                f"-DPROTOBUF_SOURCE={args.protobuf.resolve()}",
            ],
            check=True,
        )
        graph = (temporary / "targets.dot").read_text()
        labels = dict(re.findall(r'"(node\d+)" \[ label = "([^"\\]+)', graph))
        edges: dict[str, list[str]] = {}
        for parent, child in re.findall(r'"(node\d+)" -> "(node\d+)"', graph):
            edges.setdefault(parent, []).append(child)
        pending = [key for key, value in labels.items() if value in ("re2", "libprotobuf")]
        if len(pending) != 2:
            raise RuntimeError("The expected native library targets were not found")
        seen: set[str] = set()
        while pending:
            node = pending.pop()
            if node not in seen:
                seen.add(node)
                pending.extend(edges.get(node, []))
        targets = {labels[node] for node in seen}
        files: list[Path] = []
        for entry in json.loads((temporary / "build" / "compile_commands.json").read_text()):
            target = re.search(r"CMakeFiles/([^/]+)\.dir", entry["command"])
            if target and target[1] in targets:
                files.append(Path(entry["file"]).resolve())
        lines = [".{"]
        for name, root in (
            ("re2", args.re2.resolve()),
            ("abseil", args.abseil.resolve()),
            ("protobuf", args.protobuf.resolve()),
        ):
            lines.append(f"    .{name} = .{{")
            lines.extend(
                f'        "{file.relative_to(root).as_posix()}",' for file in files if file.is_relative_to(root)
            )
            lines.append("    },")
        lines.append("}")
        args.output.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
