#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const qamRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const canonicalPath = resolve(qamRoot, "contracts/qam-graph-1.0.ts");
const targets = [
  resolve(qamRoot, "packages/core/src/qam-graph-contract.ts"),
  resolve(qamRoot, "packages/mcp/src/qam-graph-contract.ts"),
];
const checkOnly = process.argv.includes("--check");
const canonical = await readFile(canonicalPath, "utf8");

for (const target of targets) {
  if (checkOnly) {
    const generated = await readFile(target, "utf8").catch(() => "");
    if (generated !== canonical) {
      throw new Error(
        `${target} is not synchronized with ${canonicalPath}; run node scripts/sync-graph-contract.mjs`,
      );
    }
  } else {
    await writeFile(target, canonical, "utf8");
  }
}

if (checkOnly) {
  process.stdout.write("qam-graph/1.0 contract copies are synchronized.\n");
}
