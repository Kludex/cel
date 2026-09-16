from __future__ import annotations

import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface
from packaging.tags import sys_tags


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        if self.target_name != "wheel":
            return
        if sys.platform == "win32":
            raise RuntimeError("Windows native builds are not supported yet")
        zig = shutil.which("zig")
        if zig is None:
            raise RuntimeError("Install Zig 0.16.0 and put zig on PATH before building cel-sdk")
        installed = subprocess.check_output([zig, "version"], text=True).strip()
        if installed != "0.16.0":
            raise RuntimeError(f"Expected Zig 0.16.0, found {installed}")
        root = Path(self.root)
        build_root = root / "zig"
        if not (build_root / "build.zig").is_file():
            build_root = root.parent.parent
        output = root / "src" / "cel" / "_native.abi3.so"
        with TemporaryDirectory(dir=output.parent, prefix=".cel-build-") as temporary:
            subprocess.run(
                [
                    zig,
                    "build",
                    "python",
                    "-Doptimize=ReleaseSafe",
                    f"-Dpython-include={sysconfig.get_path('include')}",
                    "--prefix",
                    temporary,
                ],
                cwd=build_root,
                check=True,
            )
            (Path(temporary) / "lib" / "_native.so").replace(output)
        build_data["pure_python"] = False
        build_data["tag"] = f"cp310-abi3-{next(sys_tags()).platform}"
        build_data["artifacts"] = ["src/cel/_native.abi3.so"]
