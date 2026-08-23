import { execFileSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { relative, resolve, sep } from "node:path";

import { repositoryWebUrl, sanitizeRepository } from "./repository.js";
import type { GitMetadata } from "./types.js";

function git(cwd: string, args: string[]): string | undefined {
  try {
    return execFileSync("git", ["-C", cwd, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return undefined;
  }
}

function repositoryIdentity(value: string): string {
  const sanitized = sanitizeRepository(value);
  const webUrl = repositoryWebUrl(sanitized);
  if (webUrl === undefined) return sanitized.replace(/\/+$/u, "");

  const url = new URL(webUrl);
  url.protocol = "https:";
  url.username = "";
  url.password = "";
  url.search = "";
  url.hash = "";
  url.pathname = url.pathname.replace(/\/+$/u, "").replace(/\.git$/iu, "");
  return url.toString().replace(/\/$/u, "");
}

function pathContains(parent: string, child: string): boolean {
  const path = relative(resolve(parent), resolve(child));
  return path === "" || (!path.startsWith(`..${sep}`) && path !== "..");
}

export function discoverGitMetadata(
  bundleRoot: string,
  overrides: Partial<GitMetadata> = {},
): GitMetadata {
  const root = realpathSync(resolve(bundleRoot));
  const repositoryRoot = git(root, ["rev-parse", "--show-toplevel"]);
  if (repositoryRoot === undefined || repositoryRoot.length === 0) {
    throw new Error("Bundle must be inside a Git worktree so its content can be pinned to a verified commit.");
  }

  const pathInRepository = relative(repositoryRoot, root).split(sep).join("/") || ".";
  const status = git(repositoryRoot, [
    "status",
    "--porcelain=v1",
    "--untracked-files=all",
    "--ignored=matching",
    "--",
    pathInRepository,
  ]);
  if (status === undefined) {
    throw new Error("Unable to verify whether the bundle matches the Git worktree's HEAD commit.");
  }
  if (status.length > 0) {
    throw new Error(
      "Bundle contains modified, staged, untracked, or ignored files and cannot be represented as commit-pinned. Commit or remove those changes first.",
    );
  }

  const headSha = git(repositoryRoot, ["rev-parse", "HEAD"]);
  if (headSha === undefined || headSha.length === 0) {
    throw new Error("Unable to determine the Git worktree's HEAD commit SHA.");
  }
  const githubWorkspace = process.env.GITHUB_WORKSPACE;
  const isGithubWorkspace =
    githubWorkspace !== undefined &&
    pathContains(realpathSync(resolve(githubWorkspace)), repositoryRoot);
  const requestedSha =
    overrides.gitSha ?? (isGithubWorkspace ? process.env.GITHUB_SHA : undefined);
  if (requestedSha !== undefined && requestedSha !== headSha) {
    throw new Error(`Requested Git SHA '${requestedSha}' does not match the clean worktree HEAD '${headSha}'.`);
  }
  const gitSha = headSha;

  const commitTimestamp = git(repositoryRoot, ["show", "-s", "--format=%cI", gitSha]);
  if (commitTimestamp === undefined || commitTimestamp.length === 0) {
    throw new Error("Unable to determine the clean HEAD commit timestamp.");
  }
  if (overrides.generatedAt !== undefined && overrides.generatedAt !== commitTimestamp) {
    throw new Error("Requested generatedAt does not match the clean HEAD commit timestamp.");
  }
  const generatedAt = commitTimestamp;

  const githubRepository =
    isGithubWorkspace ? process.env.GITHUB_REPOSITORY : undefined;
  const githubServerUrl = process.env.GITHUB_SERVER_URL ?? "https://github.com";
  const origin = git(repositoryRoot, ["remote", "get-url", "origin"]);
  const environmentRepository =
    githubRepository === undefined
      ? undefined
      : `${githubServerUrl.replace(/\/$/u, "")}/${githubRepository}`;
  if (
    origin !== undefined &&
    environmentRepository !== undefined &&
    repositoryIdentity(origin) !== repositoryIdentity(environmentRepository)
  ) {
    throw new Error("Git origin does not match GITHUB_REPOSITORY for this checkout.");
  }

  const discoveredRepository = environmentRepository ?? origin ?? "local";
  const repository = repositoryIdentity(discoveredRepository);
  if (
    overrides.repository !== undefined &&
    repositoryIdentity(overrides.repository) !== repository
  ) {
    throw new Error(
      `Requested repository '${sanitizeRepository(overrides.repository)}' does not match the verified Git origin '${repository}'.`,
    );
  }
  const requestedPath = overrides.pathInRepository;
  if (requestedPath !== undefined && requestedPath.replace(/^\/+|\/+$/g, "") !== pathInRepository) {
    throw new Error(
      `Requested repository path '${requestedPath}' does not match the bundle's Git path '${pathInRepository}'.`,
    );
  }

  return { gitSha, generatedAt, repository, pathInRepository };
}
