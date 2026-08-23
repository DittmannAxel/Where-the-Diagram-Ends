import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

import { resetLocalDemoArtifacts } from "../lib/local-demo-artifacts.mjs";

test("local demo cleanup preserves every sibling cloud receipt", (context) => {
  const sandbox = mkdtempSync(join(tmpdir(), "qam-local-demo-artifacts-"));
  context.after(() => rmSync(sandbox, { recursive: true, force: true }));

  const artifactParent = join(sandbox, ".artifacts");
  const localDemoRoot = join(artifactParent, "local-demo");
  const fabricReceipt = join(artifactParent, "fabric-access.json");
  const cloudReceipt = join(artifactParent, "cloud", "deployment-receipt.json");

  mkdirSync(localDemoRoot, { recursive: true });
  mkdirSync(join(artifactParent, "cloud"), { recursive: true });
  writeFileSync(join(localDemoRoot, "stale-graph.json"), "stale demo output\n");
  writeFileSync(fabricReceipt, "synthetic Fabric receipt\n");
  writeFileSync(cloudReceipt, "synthetic cloud receipt\n");

  const resetTarget = resetLocalDemoArtifacts(artifactParent);

  assert.equal(resetTarget, resolve(localDemoRoot));
  assert.equal(existsSync(localDemoRoot), false);
  assert.equal(readFileSync(fabricReceipt, "utf8"), "synthetic Fabric receipt\n");
  assert.equal(readFileSync(cloudReceipt, "utf8"), "synthetic cloud receipt\n");
});
