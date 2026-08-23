import { readFile } from "node:fs/promises";

import { afterEach, describe, expect, it } from "vitest";

import { runCli } from "../src/cli.js";
import { createBundle, createGitBundle, removeTemporaryDirectories, temporaryDirectory } from "./helpers.js";

afterEach(removeTemporaryDirectories);

function captureIo(): { stdout: string[]; stderr: string[]; io: Parameters<typeof runCli>[1] } {
  const stdout: string[] = [];
  const stderr: string[] = [];
  return {
    stdout,
    stderr,
    io: {
      stdout: (value) => stdout.push(value),
      stderr: (value) => stderr.push(value),
    },
  };
}

describe("qam-core CLI", () => {
  it("validates a bundle as machine-readable JSON", async () => {
    const bundle = await createBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });
    const capture = captureIo();

    const exitCode = await runCli(["validate", bundle, "--json"], capture.io);

    expect(exitCode).toBe(0);
    expect(capture.stderr).toEqual([]);
    expect(JSON.parse(capture.stdout.join(""))).toMatchObject({
      valid: true,
      strictValid: true,
      summary: { errors: 0, warnings: 0 },
    });
  });

  it("returns exit code one for conformance errors", async () => {
    const bundle = await createBundle({ "concept.md": "Body\n" });
    const capture = captureIo();
    expect(await runCli(["validate", bundle], capture.io)).toBe(1);
    expect(capture.stdout.join("")).toContain("MISSING_FRONTMATTER");
  });

  it("projects a clean Git bundle with verified commit metadata", async () => {
    const fixture = await createGitBundle({
      "concept.md": "---\ntype: Concept\ntitle: CLI\n---\nBody\n",
    });
    const output = await temporaryDirectory("qam-cli-output-");
    const capture = captureIo();
    const exitCode = await runCli(
      [
        "project",
        fixture.bundle,
        "--output",
        output,
        "--repository",
        "https://github.com/example/repository",
      ],
      capture.io,
    );

    expect(exitCode).toBe(0);
    expect(capture.stderr).toEqual([]);
    const graph = JSON.parse(await readFile(`${output}/graph.json`, "utf8")) as {
      source: { commitSha: string };
      nodes: Array<{ title: string }>;
    };
    expect(graph.source.commitSha).toBe(fixture.gitSha);
    expect(graph.nodes[0]?.title).toBe("CLI");
  });

  it("shows version and rejects unknown options", async () => {
    const version = captureIo();
    expect(await runCli(["--version"], version.io)).toBe(0);
    expect(version.stdout.join("")).toBe("0.1.0\n");

    const unknown = captureIo();
    expect(await runCli(["validate", ".", "--unknown"], unknown.io)).toBe(2);
    expect(unknown.stderr.join("")).toContain("Unknown option");
  });
});
