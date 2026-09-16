import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, renameSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const directory = dirname(fileURLToPath(import.meta.url));
const root = resolve(directory, "../..");
const include = [
  process.env.NODE_INCLUDE,
  resolve(dirname(process.execPath), "../include/node"),
  "/usr/include/node",
  "/usr/local/include/node",
  "/opt/homebrew/include/node",
].find((path) => path !== undefined && existsSync(join(path, "node_api.h")));
if (include === undefined) {
  throw new Error(
    "Install Node headers or set NODE_INCLUDE to the directory containing node_api.h",
  );
}
const result = spawnSync(
  "zig",
  ["build", "node", `-Dnode-include=${include}`, "-Doptimize=ReleaseSafe"],
  { cwd: root, stdio: "inherit" },
);
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
const temporary = mkdtempSync(join(directory, ".cel-build-"));
try {
  copyFileSync(join(root, "zig-out/lib/cel.node"), join(temporary, "cel.node"));
  renameSync(join(temporary, "cel.node"), join(directory, "cel.node"));
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
