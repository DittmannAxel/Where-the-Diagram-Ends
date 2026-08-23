import { execFileSync } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";

function command(command, args, options = {}) {
  try {
    return execFileSync(command, args, {
      cwd: options.cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  } catch (error) {
    if (options.allowFailure === true) return null;
    const detail = error?.stderr?.toString().trim() || error?.message || String(error);
    throw new Error(`${command} ${args.join(" ")} failed: ${detail}`);
  }
}

export async function readJson(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(`Could not read JSON '${path}': ${detail}`);
  }
}

export async function atomicWriteJson(path, value) {
  await atomicWriteText(path, `${JSON.stringify(value, null, 2)}\n`);
}

export async function atomicWriteText(path, content) {
  await mkdir(dirname(resolve(path)), { recursive: true });
  const temporary = `${path}.tmp-${process.pid}`;
  await writeFile(temporary, content, { encoding: "utf8", mode: 0o644 });
  await rename(temporary, path);
}

export function gitSnapshot(knowledgeRoot, requestedCommit) {
  const gitRootRaw = command("git", ["-C", knowledgeRoot, "rev-parse", "--show-toplevel"], {
    allowFailure: true,
  });
  if (gitRootRaw === null) {
    if (requestedCommit === undefined) {
      throw new Error("--commit is required when the knowledge directory is outside a Git worktree");
    }
    return {
      git_root: null,
      commit_sha: validateCommit(requestedCommit),
      commit_generated_at: "1970-01-01T00:00:00Z",
      path_in_repository: "data/knowledge",
      repository: "local/industrial-component-obsolescence",
      tracked: false,
      clean_at_commit: false,
      untracked_files: [],
    };
  }

  const gitRoot = resolve(gitRootRaw);
  const commit = validateCommit(
    requestedCommit ?? command("git", ["-C", gitRoot, "rev-parse", "HEAD"]),
  );
  if (
    command("git", ["-C", gitRoot, "cat-file", "-e", `${commit}^{commit}`], {
      allowFailure: true,
    }) === null
  ) {
    throw new Error(`Selected commit '${commit}' is not available in the local Git repository`);
  }

  const relativeKnowledge = relative(gitRoot, resolve(knowledgeRoot)).split(sep).join("/");
  if (relativeKnowledge === ".." || relativeKnowledge.startsWith("../")) {
    throw new Error("Knowledge directory must be inside its discovered Git worktree");
  }
  const tracked =
    command(
      "git",
      ["-C", gitRoot, "ls-files", "--error-unmatch", "--", `${relativeKnowledge}/index.md`],
      { allowFailure: true },
    ) !== null;
  const diffClean =
    command("git", ["-C", gitRoot, "diff", "--quiet", commit, "--", relativeKnowledge], {
      allowFailure: true,
    }) !== null;
  const untrackedOutput =
    command(
      "git",
      ["-C", gitRoot, "ls-files", "--others", "--exclude-standard", "--", relativeKnowledge],
      { allowFailure: true },
    ) ?? "";
  const untrackedFiles = untrackedOutput.length === 0 ? [] : untrackedOutput.split("\n").sort();
  const remote = command("git", ["-C", gitRoot, "remote", "get-url", "origin"], {
    allowFailure: true,
  });
  const commitGeneratedAt = command("git", [
    "-C",
    gitRoot,
    "show",
    "-s",
    "--format=%cI",
    commit,
  ]);

  return {
    git_root: gitRoot,
    commit_sha: commit,
    commit_generated_at: commitGeneratedAt,
    path_in_repository: relativeKnowledge,
    repository: remote ?? "local/industrial-component-obsolescence",
    tracked,
    clean_at_commit: tracked && diffClean && untrackedFiles.length === 0,
    untracked_files: untrackedFiles,
  };
}

export function validateCommit(value) {
  const commit = String(value).trim();
  if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/u.test(commit)) {
    throw new TypeError("Commit must be a lowercase full 40/64-character Git SHA");
  }
  return commit;
}

export function dataPaths(dataRoot) {
  const root = resolve(dataRoot);
  return {
    root,
    knowledge: join(root, "knowledge"),
    questions: join(root, "questions", "questions.json"),
    gold: join(root, "gold", "gold.json"),
  };
}
