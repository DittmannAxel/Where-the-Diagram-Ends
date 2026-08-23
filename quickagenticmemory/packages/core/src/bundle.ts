import { readdir, readFile, stat } from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";

import { compareText } from "./hash.js";
import { parseMarkdownDocument } from "./markdown.js";
import type { Diagnostic, KnowledgeBundle, ParsedDocument } from "./types.js";

const EXCLUDED_DIRECTORIES = new Set([".git", "node_modules"]);

async function walkMarkdownFiles(
  root: string,
  directory: string,
  diagnostics: Diagnostic[],
): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  entries.sort((left, right) => compareText(left.name, right.name));
  const files: string[] = [];

  for (const entry of entries) {
    const absolutePath = join(directory, entry.name);
    const relativePath = relative(root, absolutePath).split(sep).join("/");
    if (entry.isSymbolicLink()) {
      diagnostics.push({
        severity: "info",
        code: "SYMLINK_SKIPPED",
        message: "Symbolic links are not followed while loading a bundle.",
        path: relativePath,
      });
      continue;
    }
    if (entry.isDirectory()) {
      if (!EXCLUDED_DIRECTORIES.has(entry.name)) {
        files.push(...(await walkMarkdownFiles(root, absolutePath, diagnostics)));
      }
      continue;
    }
    if (entry.isFile() && entry.name.toLocaleLowerCase("en-US").endsWith(".md")) {
      files.push(absolutePath);
    }
  }

  return files;
}

export async function loadBundle(rootPath: string): Promise<KnowledgeBundle> {
  const root = resolve(rootPath);
  const rootStat = await stat(root);
  if (!rootStat.isDirectory()) throw new Error(`Bundle path is not a directory: ${root}`);

  const diagnostics: Diagnostic[] = [];
  const documents: ParsedDocument[] = [];
  const files = await walkMarkdownFiles(root, root, diagnostics);

  for (const absolutePath of files.sort(compareText)) {
    const path = relative(root, absolutePath).split(sep).join("/");
    const bytes = await readFile(absolutePath);
    let raw: string;
    try {
      raw = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    } catch {
      diagnostics.push({
        severity: "error",
        code: "INVALID_UTF8",
        message: "OKF documents must be valid UTF-8.",
        path,
      });
      continue;
    }

    const parsed = parseMarkdownDocument(path, raw);
    documents.push(parsed.document);
    diagnostics.push(...parsed.diagnostics);
  }

  documents.sort((left, right) => compareText(left.path, right.path));
  diagnostics.sort(compareDiagnostics);
  const rootIndex = documents.find((document) => document.path === "index.md");
  const declaredVersion = rootIndex?.frontmatter.okf_version;

  return {
    root,
    documents,
    diagnostics,
    ...(typeof declaredVersion === "string" ? { okfVersion: declaredVersion } : {}),
  };
}

export function compareDiagnostics(left: Diagnostic, right: Diagnostic): number {
  const byPath = compareText(left.path, right.path);
  if (byPath !== 0) return byPath;
  const byLine = (left.line ?? 0) - (right.line ?? 0);
  if (byLine !== 0) return byLine;
  const byColumn = (left.column ?? 0) - (right.column ?? 0);
  if (byColumn !== 0) return byColumn;
  return compareText(left.code, right.code);
}
