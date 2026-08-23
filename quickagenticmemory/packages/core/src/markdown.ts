import { posix } from "node:path";

import type { Nodes, Root } from "mdast";
import { fromMarkdown } from "mdast-util-from-markdown";
import { parseDocument as parseYamlDocument } from "yaml";

import { sha256 } from "./hash.js";
import type {
  Diagnostic,
  DocumentKind,
  Frontmatter,
  MarkdownLink,
  ParsedDocument,
} from "./types.js";

export interface ParseResult {
  document: ParsedDocument;
  diagnostics: Diagnostic[];
}

function documentKind(relativePath: string): DocumentKind {
  const filename = posix.basename(relativePath).toLocaleLowerCase("en-US");
  if (filename === "index.md") return "index";
  if (filename === "log.md") return "log";
  return "concept";
}

function plainText(node: Nodes): string {
  if ("value" in node && typeof node.value === "string") return node.value;
  if ("children" in node && Array.isArray(node.children)) {
    return node.children.map((child) => plainText(child)).join("");
  }
  return "";
}

function extractLinks(body: string): MarkdownLink[] {
  const tree: Root = fromMarkdown(body);
  const definitions = new Map<string, string>();
  const links: MarkdownLink[] = [];

  function collectDefinitions(node: Nodes): void {
    if (node.type === "definition") {
      definitions.set(node.identifier.toLocaleLowerCase("en-US"), node.url);
    }
    if ("children" in node && Array.isArray(node.children)) {
      for (const child of node.children) collectDefinitions(child);
    }
  }

  function collectLinks(node: Nodes): void {
    let target: string | undefined;
    if (node.type === "link") target = node.url;
    if (node.type === "linkReference") {
      target = definitions.get(node.identifier.toLocaleLowerCase("en-US"));
    }

    if (target !== undefined) {
      const line = node.position?.start.line;
      const column = node.position?.start.column;
      links.push({
        label: plainText(node),
        target,
        ...(line === undefined ? {} : { line }),
        ...(column === undefined ? {} : { column }),
      });
    }

    if ("children" in node && Array.isArray(node.children)) {
      for (const child of node.children) collectLinks(child);
    }
  }

  collectDefinitions(tree);
  collectLinks(tree);
  return links;
}

function yamlErrorDiagnostic(
  relativePath: string,
  message: string,
  line?: number,
  column?: number,
): Diagnostic {
  return {
    severity: "error",
    code: "INVALID_FRONTMATTER",
    message,
    path: relativePath,
    ...(line === undefined ? {} : { line }),
    ...(column === undefined ? {} : { column }),
  };
}

function parseFrontmatter(
  relativePath: string,
  raw: string,
): {
  frontmatter: Frontmatter;
  hasFrontmatter: boolean;
  bodyLineOffset: number;
  body: string;
  diagnostics: Diagnostic[];
} {
  const withoutBom = raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw;
  const normalized = withoutBom.replace(/\r\n?/g, "\n");
  const lines = normalized.split("\n");

  if (lines[0] !== "---") {
    return {
      frontmatter: {},
      hasFrontmatter: false,
      bodyLineOffset: 0,
      body: normalized,
      diagnostics: [],
    };
  }

  const closingLine = lines.findIndex((line, index) => index > 0 && line === "---");
  if (closingLine === -1) {
    return {
      frontmatter: {},
      hasFrontmatter: true,
      bodyLineOffset: lines.length,
      body: "",
      diagnostics: [
        yamlErrorDiagnostic(relativePath, "Frontmatter starts with '---' but has no closing delimiter.", 1, 1),
      ],
    };
  }

  const yamlSource = lines.slice(1, closingLine).join("\n");
  const body = lines.slice(closingLine + 1).join("\n");
  const yamlDocument = parseYamlDocument(yamlSource, {
    prettyErrors: false,
    strict: true,
    uniqueKeys: true,
  });

  const diagnostics: Diagnostic[] = yamlDocument.errors.map((error) => {
    const location = error.linePos?.[0];
    return yamlErrorDiagnostic(
      relativePath,
      error.message,
      location === undefined ? undefined : location.line + 1,
      location?.col,
    );
  });

  if (diagnostics.length > 0) {
    return {
      frontmatter: {},
      hasFrontmatter: true,
      bodyLineOffset: closingLine + 1,
      body,
      diagnostics,
    };
  }

  let parsed: unknown;
  try {
    parsed = yamlDocument.toJS({ maxAliasCount: 100 });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unable to decode YAML frontmatter.";
    return {
      frontmatter: {},
      hasFrontmatter: true,
      bodyLineOffset: closingLine + 1,
      body,
      diagnostics: [yamlErrorDiagnostic(relativePath, message)],
    };
  }

  if (parsed === null && yamlSource.trim() === "") parsed = {};
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return {
      frontmatter: {},
      hasFrontmatter: true,
      bodyLineOffset: closingLine + 1,
      body,
      diagnostics: [
        yamlErrorDiagnostic(relativePath, "Frontmatter must decode to a YAML mapping/object.", 2, 1),
      ],
    };
  }

  return {
    frontmatter: parsed as Frontmatter,
    hasFrontmatter: true,
    bodyLineOffset: closingLine + 1,
    body,
    diagnostics,
  };
}

export function parseMarkdownDocument(relativePath: string, raw: string): ParseResult {
  const path = relativePath.replaceAll("\\", "/").replace(/^\.\//, "");
  const kind = documentKind(path);
  const parsed = parseFrontmatter(path, raw);
  const diagnostics = [...parsed.diagnostics];
  let links: MarkdownLink[] = [];

  try {
    links = extractLinks(parsed.body);
  } catch (error) {
    diagnostics.push({
      severity: "warning",
      code: "MARKDOWN_PARSE_ERROR",
      message: error instanceof Error ? error.message : "Unable to parse Markdown body.",
      path,
    });
  }

  const conceptId = kind === "concept" ? path.slice(0, -".md".length) : undefined;
  return {
    document: {
      kind,
      path,
      ...(conceptId === undefined ? {} : { conceptId }),
      frontmatter: parsed.frontmatter,
      hasFrontmatter: parsed.hasFrontmatter,
      bodyLineOffset: parsed.bodyLineOffset,
      body: parsed.body,
      raw,
      contentHash: sha256(raw),
      links,
    },
    diagnostics,
  };
}

export function normalizeVerified(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  if (typeof value === "object" && value !== null) return [value];
  return [];
}
