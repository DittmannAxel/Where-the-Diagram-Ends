import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const temporaryDirectories: string[] = [];

export async function temporaryDirectory(prefix = "qam-core-"): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  temporaryDirectories.push(directory);
  return directory;
}

export async function createBundle(files: Record<string, string | Uint8Array>): Promise<string> {
  const root = await temporaryDirectory("qam-bundle-");
  for (const [path, content] of Object.entries(files)) {
    const absolutePath = join(root, path);
    await mkdir(dirname(absolutePath), { recursive: true });
    await writeFile(absolutePath, content);
  }
  return root;
}

export interface GitBundle {
  repository: string;
  bundle: string;
  gitSha: string;
  generatedAt: string;
}

export function runGit(repository: string, args: string[]): string {
  return execFileSync("git", ["-C", repository, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      GIT_AUTHOR_DATE: "2026-08-22T12:00:00Z",
      GIT_COMMITTER_DATE: "2026-08-22T12:00:00Z",
    },
  }).trim();
}

export async function createGitBundle(files: Record<string, string>): Promise<GitBundle> {
  const repository = await temporaryDirectory("qam-git-repository-");
  const bundle = join(repository, "knowledge");
  for (const [path, content] of Object.entries(files)) {
    const absolutePath = join(bundle, path);
    await mkdir(dirname(absolutePath), { recursive: true });
    await writeFile(absolutePath, content);
  }
  runGit(repository, ["init", "--quiet"]);
  runGit(repository, ["config", "user.name", "Quick Agentic Memory Tests"]);
  runGit(repository, ["config", "user.email", "qam-tests@example.invalid"]);
  runGit(repository, ["remote", "add", "origin", "https://github.com/example/repository.git"]);
  runGit(repository, ["add", "knowledge"]);
  runGit(repository, ["commit", "--quiet", "-m", "Add test knowledge bundle"]);
  return {
    repository,
    bundle,
    gitSha: runGit(repository, ["rev-parse", "HEAD"]),
    generatedAt: runGit(repository, ["show", "-s", "--format=%cI", "HEAD"]),
  };
}

export async function removeTemporaryDirectories(): Promise<void> {
  await Promise.all(
    temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })),
  );
}
