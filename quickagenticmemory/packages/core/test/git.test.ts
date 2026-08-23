import { writeFile } from "node:fs/promises";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { discoverGitMetadata } from "../src/git.js";
import { createGitBundle, removeTemporaryDirectories } from "./helpers.js";

afterEach(async () => {
  vi.unstubAllEnvs();
  await removeTemporaryDirectories();
});

describe("Git projection metadata", () => {
  it("ignores GitHub metadata inherited by an unrelated checkout", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });
    vi.stubEnv("GITHUB_WORKSPACE", process.cwd());
    vi.stubEnv("GITHUB_SHA", "0000000000000000000000000000000000000000");

    expect(discoverGitMetadata(fixture.bundle).gitSha).toBe(fixture.gitSha);
  });

  it("rejects a GitHub SHA that disagrees inside the Actions workspace", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });
    vi.stubEnv("GITHUB_WORKSPACE", fixture.repository);
    vi.stubEnv("GITHUB_SHA", "0000000000000000000000000000000000000000");

    expect(() => discoverGitMetadata(fixture.bundle)).toThrow(
      "does not match the clean worktree HEAD",
    );
  });

  it("rejects an explicit SHA mismatch outside the Actions workspace", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });

    expect(() =>
      discoverGitMetadata(fixture.bundle, {
        gitSha: "0000000000000000000000000000000000000000",
      }),
    ).toThrow("does not match the clean worktree HEAD");
  });

  it("removes credentials from HTTP repository URLs", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });
    const metadata = discoverGitMetadata(fixture.bundle, {
      repository: "https://token:secret@github.com/example/repository.git",
    });

    expect(metadata.repository).toBe("https://github.com/example/repository");
    expect(metadata.repository).not.toContain("token");
    expect(metadata.repository).not.toContain("secret");
  });

  it("normalizes credential-like SCP usernames to the non-secret git user", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });
    const metadata = discoverGitMetadata(fixture.bundle, {
      repository: "sensitive-user@github.com:example/repository.git",
    });

    expect(metadata.repository).toBe("https://github.com/example/repository");
  });

  it("treats SSH and HTTPS forms of the same verified origin as equivalent", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });

    expect(
      discoverGitMetadata(fixture.bundle, {
        repository: "git@github.com:example/repository.git",
      }).repository,
    ).toBe("https://github.com/example/repository");
  });

  it("rejects a repository override that does not match the verified origin", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });

    expect(() =>
      discoverGitMetadata(fixture.bundle, {
        repository: "https://github.com/attacker/substitute",
      }),
    ).toThrow("does not match the verified Git origin");
  });

  it("accepts matching GitHub Actions checkout metadata as an independent assertion", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });
    vi.stubEnv("GITHUB_WORKSPACE", fixture.repository);
    vi.stubEnv("GITHUB_REPOSITORY", "example/repository");
    vi.stubEnv("GITHUB_SERVER_URL", "https://github.com");
    vi.stubEnv("GITHUB_SHA", fixture.gitSha);

    expect(discoverGitMetadata(fixture.bundle).repository).toBe(
      "https://github.com/example/repository",
    );
  });

  it("rejects GitHub Actions metadata that disagrees with the verified origin", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });
    vi.stubEnv("GITHUB_WORKSPACE", fixture.repository);
    vi.stubEnv("GITHUB_REPOSITORY", "attacker/substitute");
    vi.stubEnv("GITHUB_SERVER_URL", "https://github.com");
    vi.stubEnv("GITHUB_SHA", fixture.gitSha);

    expect(() => discoverGitMetadata(fixture.bundle)).toThrow(
      "Git origin does not match GITHUB_REPOSITORY",
    );
  });

  it("fails closed for a modified tracked bundle file even with explicit metadata", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nOriginal\n" });
    await writeFile(join(fixture.bundle, "concept.md"), "---\ntype: Concept\n---\nModified\n");

    expect(() =>
      discoverGitMetadata(fixture.bundle, {
        gitSha: fixture.gitSha,
        generatedAt: fixture.generatedAt,
        repository: "https://github.com/example/repository",
        pathInRepository: "knowledge",
      }),
    ).toThrow("cannot be represented as commit-pinned");
  });

  it("fails closed for an untracked bundle file", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });
    await writeFile(join(fixture.bundle, "untracked.md"), "---\ntype: Concept\n---\nUntracked\n");

    expect(() => discoverGitMetadata(fixture.bundle)).toThrow("cannot be represented as commit-pinned");
  });

  it("does not block projection for worktree changes outside the bundle", async () => {
    const fixture = await createGitBundle({ "concept.md": "---\ntype: Concept\n---\nBody\n" });
    await writeFile(join(fixture.repository, "outside.txt"), "Untracked outside the knowledge bundle.\n");

    expect(discoverGitMetadata(fixture.bundle)).toMatchObject({
      gitSha: fixture.gitSha,
      generatedAt: fixture.generatedAt,
      pathInRepository: "knowledge",
    });
  });
});
