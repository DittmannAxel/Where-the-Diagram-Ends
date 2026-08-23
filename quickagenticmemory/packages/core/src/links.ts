import { posix } from "node:path";

import type { KnowledgeBundle, MarkdownLink, ParsedDocument } from "./types.js";

export type LinkResolutionKind =
  | "concept"
  | "reserved"
  | "broken"
  | "outside"
  | "external"
  | "fragment";

export interface LinkResolution {
  kind: LinkResolutionKind;
  path?: string;
}

function stripQueryAndFragment(target: string): string {
  const queryIndex = target.indexOf("?");
  const fragmentIndex = target.indexOf("#");
  const indexes = [queryIndex, fragmentIndex].filter((index) => index >= 0);
  const end = indexes.length === 0 ? target.length : Math.min(...indexes);
  return target.slice(0, end);
}

export function resolveLink(
  bundle: KnowledgeBundle,
  source: ParsedDocument,
  link: MarkdownLink,
): LinkResolution {
  const target = link.target.trim();
  if (target.startsWith("#")) return { kind: "fragment" };
  if (/^[A-Za-z][A-Za-z\d+.-]*:/.test(target) || target.startsWith("//")) {
    return { kind: "external" };
  }

  let decoded: string;
  try {
    decoded = decodeURIComponent(stripQueryAndFragment(target));
  } catch {
    decoded = stripQueryAndFragment(target);
  }
  if (decoded.length === 0) return { kind: "fragment" };

  const bundleRelative = decoded.startsWith("/")
    ? posix.normalize(decoded.slice(1))
    : posix.normalize(posix.join(posix.dirname(source.path), decoded));
  if (bundleRelative === ".." || bundleRelative.startsWith("../") || posix.isAbsolute(bundleRelative)) {
    return { kind: "outside", path: bundleRelative };
  }

  const candidates = [bundleRelative];
  if (bundleRelative.endsWith("/")) candidates.push(`${bundleRelative}index.md`);
  if (posix.extname(bundleRelative) === "") candidates.push(`${bundleRelative}.md`);

  for (const candidate of candidates) {
    const document = bundle.documents.find((entry) => entry.path === candidate);
    if (document?.kind === "concept") return { kind: "concept", path: candidate };
    if (document !== undefined) return { kind: "reserved", path: candidate };
  }

  return { kind: "broken", path: bundleRelative };
}
