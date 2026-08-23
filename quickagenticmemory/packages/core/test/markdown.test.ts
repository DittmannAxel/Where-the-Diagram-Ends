import { afterEach, describe, expect, it } from "vitest";

import { normalizeVerified, parseMarkdownDocument } from "../src/markdown.js";
import { removeTemporaryDirectories } from "./helpers.js";

afterEach(removeTemporaryDirectories);

describe("parseMarkdownDocument", () => {
  it("parses BOM/CRLF frontmatter, standard links, and reference links", () => {
    const result = parseMarkdownDocument(
      "concepts/alpha.md",
      "\ufeff---\r\ntype: Concept\r\ntitle: Alpha\r\nverified: { by: human:axel, at: 2026-08-22T10:00:00Z }\r\ncustom: kept\r\n---\r\n# Alpha\r\n\r\n[Neighbor](./beta.md) and [Reference][beta].\r\n\r\n![Ignored image](image.png)\r\n\r\n[beta]: /concepts/beta.md\r\n",
    );

    expect(result.diagnostics).toEqual([]);
    expect(result.document.kind).toBe("concept");
    expect(result.document.conceptId).toBe("concepts/alpha");
    expect(result.document.frontmatter.custom).toBe("kept");
    expect(result.document.body).toContain("# Alpha\n");
    expect(result.document.links).toEqual([
      expect.objectContaining({ label: "Neighbor", target: "./beta.md" }),
      expect.objectContaining({ label: "Reference", target: "/concepts/beta.md" }),
    ]);
    expect(normalizeVerified(result.document.frontmatter.verified)).toHaveLength(1);
  });

  it("reports duplicate YAML keys and preserves a usable parse result", () => {
    const result = parseMarkdownDocument("broken.md", "---\ntype: One\ntype: Two\n---\nBody\n");

    expect(result.diagnostics).toEqual([
      expect.objectContaining({ severity: "error", code: "INVALID_FRONTMATTER", path: "broken.md" }),
    ]);
    expect(result.document.frontmatter).toEqual({});
    expect(result.document.body).toBe("Body\n");
  });

  it("classifies reserved files and allows them to omit frontmatter", () => {
    const index = parseMarkdownDocument("index.md", "# Concepts\n\n* [One](one.md)\n");
    const log = parseMarkdownDocument("nested/log.md", "# Log\n\n## 2026-08-22\n* Created.\n");

    expect(index.document.kind).toBe("index");
    expect(log.document.kind).toBe("log");
    expect(index.document.hasFrontmatter).toBe(false);
    expect(log.document.hasFrontmatter).toBe(false);
  });

  it("rejects a non-mapping frontmatter value", () => {
    const result = parseMarkdownDocument("list.md", "---\n- one\n- two\n---\nBody\n");
    expect(result.diagnostics[0]).toMatchObject({ code: "INVALID_FRONTMATTER", severity: "error" });
  });
});
