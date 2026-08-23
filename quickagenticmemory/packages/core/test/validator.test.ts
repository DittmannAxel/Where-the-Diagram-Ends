import { afterEach, describe, expect, it } from "vitest";

import { validateBundle } from "../src/validator.js";
import { createBundle, removeTemporaryDirectories } from "./helpers.js";

afterEach(removeTemporaryDirectories);

describe("OKF v0.2 bundle validation", () => {
  it("accepts the minimal conformant concept and tolerates a broken link", async () => {
    const bundle = await createBundle({
      "index.md": "---\nokf_version: \"0.2\"\n---\n# Concepts\n\n* [Minimal](minimal.md) - Minimal concept\n",
      "minimal.md": "---\ntype: Experimental Thing\nunknown_extension: true\n---\nSee [future knowledge](future.md).\n",
    });

    const result = await validateBundle(bundle);

    expect(result.valid).toBe(true);
    expect(result.summary.errors).toBe(0);
    expect(result.diagnostics).toContainEqual(
      expect.objectContaining({ code: "BROKEN_LINK", severity: "warning" }),
    );
    expect(result.diagnostics.some((diagnostic) => diagnostic.code.includes("UNKNOWN"))).toBe(false);
  });

  it("rejects missing frontmatter and missing type as hard conformance errors", async () => {
    const bundle = await createBundle({
      "plain.md": "# No frontmatter\n",
      "empty-type.md": "---\ntype: \"  \"\n---\nBody\n",
    });

    const result = await validateBundle(bundle);

    expect(result.valid).toBe(false);
    expect(result.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ path: "plain.md", code: "MISSING_FRONTMATTER", severity: "error" }),
        expect.objectContaining({ path: "empty-type.md", code: "TYPE_REQUIRED", severity: "error" }),
      ]),
    );
  });

  it("normalizes bare verified mappings and validates optional families softly", async () => {
    const bundle = await createBundle({
      "attested.md": `---
type: Attested Computation
generated: { by: generator/1.0, at: 2026-08-22T10:00:00Z }
verified: { by: human:axel, at: 2026-08-22T11:00:00+02:00 }
status: stable
sources:
  - id: spec
    resource: https://example.test/spec
    usage_count: 12
    last_modified: 2026-08-20T00:00:00Z
usage_window: { from: 2026-08-01T00:00:00Z, to: 2026-08-22T00:00:00Z }
---
# Computation
`,
    });

    const result = await validateBundle(bundle);

    expect(result.valid).toBe(true);
    expect(result.diagnostics.some((diagnostic) => diagnostic.code === "INVALID_VERIFIED")).toBe(false);
    expect(result.diagnostics).toContainEqual(
      expect.objectContaining({ code: "ATTESTED_RUNTIME_REQUIRED", severity: "warning" }),
    );
  });

  it("reports malformed optional fields without rejecting a concept", async () => {
    const bundle = await createBundle({
      "soft.md": `---
type: Concept
tags: azure
generated: { by: not-an-actor, at: yesterday }
verified: invalid
status: obsolete
stale_after: 2026-08-22
sources:
  - id: duplicate
  - id: duplicate
    resource: https://example.test
    usage_count: -1
---
Body
`,
    });

    const result = await validateBundle(bundle);

    expect(result.valid).toBe(true);
    expect(result.summary.errors).toBe(0);
    expect(result.diagnostics.map((diagnostic) => diagnostic.code)).toEqual(
      expect.arrayContaining([
        "INVALID_TAGS",
        "INVALID_ACTOR",
        "INVALID_TIMESTAMP",
        "INVALID_VERIFIED",
        "INVALID_STATUS",
        "SOURCE_RESOURCE_REQUIRED",
        "DUPLICATE_SOURCE_ID",
        "INVALID_USAGE_COUNT",
      ]),
    );
  });

  it("enforces reserved index and log structures", async () => {
    const bundle = await createBundle({
      "nested/index.md": "---\ntype: Concept\n---\nNot an index.\n",
      "log.md": "---\ntype: Log\n---\n# Log\n\n## 2026-02-30\n* Impossible.\n",
    });

    const result = await validateBundle(bundle);

    expect(result.valid).toBe(false);
    expect(result.diagnostics.map((diagnostic) => diagnostic.code)).toEqual(
      expect.arrayContaining([
        "INDEX_FRONTMATTER_NOT_ALLOWED",
        "INDEX_SECTION_REQUIRED",
        "LOG_FRONTMATTER_NOT_ALLOWED",
        "INVALID_LOG_DATE",
      ]),
    );
  });

  it("reports non-UTF-8 documents", async () => {
    const bundle = await createBundle({ "invalid.md": new Uint8Array([0xff, 0xfe, 0xfd]) });
    const result = await validateBundle(bundle);
    expect(result.valid).toBe(false);
    expect(result.diagnostics).toContainEqual(
      expect.objectContaining({ path: "invalid.md", code: "INVALID_UTF8", severity: "error" }),
    );
  });

  it("continues best-effort for an unknown declared version and checks log ordering", async () => {
    const bundle = await createBundle({
      "index.md": "---\nokf_version: \"9.9\"\n---\n# Concepts\n\n* [One](one.md)\n",
      "one.md": "---\ntype: Concept\n---\nBody\n",
      "log.md": "# Log\n\n## 2026-08-01\n* First.\n\n## 2026-08-22\n* Newer.\n",
    });
    const result = await validateBundle(bundle);

    expect(result.valid).toBe(true);
    expect(result.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ code: "UNSUPPORTED_OKF_VERSION", severity: "warning" }),
        expect.objectContaining({ code: "LOG_NOT_NEWEST_FIRST", severity: "warning" }),
      ]),
    );
  });

  it("accepts a complete inline Attested Computation", async () => {
    const bundle = await createBundle({
      "calculation.md": `---
type: Attested Computation
runtime: python
parameters:
  - { name: year, type: integer, required: true }
executor: { resource: references/run.md, receipt: [result] }
attester: { resource: references/attest.py }
---
# Computation

\`\`\`python
print(year)
\`\`\`
`,
    });
    const result = await validateBundle(bundle);

    expect(result.valid).toBe(true);
    expect(result.diagnostics.some((diagnostic) => diagnostic.code === "COMPUTATION_REQUIRED")).toBe(false);
    expect(result.diagnostics.some((diagnostic) => diagnostic.code === "ATTESTED_RUNTIME_REQUIRED")).toBe(false);
  });

  it("validates calendar components in timestamps", async () => {
    const bundle = await createBundle({
      "date.md": "---\ntype: Concept\nstale_after: 2026-02-30T00:00:00Z\n---\nBody\n",
    });
    const result = await validateBundle(bundle);
    expect(result.valid).toBe(true);
    expect(result.diagnostics).toContainEqual(
      expect.objectContaining({ code: "INVALID_TIMESTAMP", severity: "warning" }),
    );
  });
});
