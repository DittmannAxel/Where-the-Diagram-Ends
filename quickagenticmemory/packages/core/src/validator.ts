import { compareDiagnostics, loadBundle } from "./bundle.js";
import { conceptUid, isRecord, nonEmptyString } from "./frontmatter.js";
import { resolveLink } from "./links.js";
import { normalizeVerified } from "./markdown.js";
import { isIsoDatetimeWithOffset } from "./time.js";
import type {
  BundleValidationResult,
  Diagnostic,
  DiagnosticSeverity,
  KnowledgeBundle,
  ParsedDocument,
  ValidationSummary,
} from "./types.js";
import { OKF_VERSION } from "./types.js";

function addDiagnostic(
  diagnostics: Diagnostic[],
  document: ParsedDocument,
  severity: DiagnosticSeverity,
  code: string,
  message: string,
): void {
  diagnostics.push({ severity, code, message, path: document.path });
}

function isActor(value: unknown): value is string {
  return (
    typeof value === "string" &&
    (/^human:\S+$/.test(value) || /^process:\S+$/.test(value) || /^\S+\/\S+$/.test(value))
  );
}

function validateDatetime(
  diagnostics: Diagnostic[],
  document: ParsedDocument,
  field: string,
  value: unknown,
): void {
  if (!isIsoDatetimeWithOffset(value)) {
    addDiagnostic(
      diagnostics,
      document,
      "warning",
      "INVALID_TIMESTAMP",
      `${field} must be an ISO 8601 datetime with an explicit UTC offset.`,
    );
  }
}

function validateUsageWindow(
  diagnostics: Diagnostic[],
  document: ParsedDocument,
  field: string,
  value: unknown,
): void {
  if (!isRecord(value)) {
    addDiagnostic(diagnostics, document, "warning", "INVALID_USAGE_WINDOW", `${field} must be a mapping.`);
    return;
  }
  validateDatetime(diagnostics, document, `${field}.from`, value.from);
  validateDatetime(diagnostics, document, `${field}.to`, value.to);
}

function validateSources(
  diagnostics: Diagnostic[],
  document: ParsedDocument,
  value: unknown,
): void {
  if (!Array.isArray(value)) {
    addDiagnostic(diagnostics, document, "warning", "INVALID_SOURCES", "sources must be a YAML list.");
    return;
  }

  const sourceIds = new Set<string>();
  value.forEach((source, index) => {
    if (!isRecord(source)) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "INVALID_SOURCE",
        `sources[${index}] must be a mapping.`,
      );
      return;
    }
    if (nonEmptyString(source.resource) === undefined) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "SOURCE_RESOURCE_REQUIRED",
        `sources[${index}].resource must be a non-empty string.`,
      );
    }
    const id = nonEmptyString(source.id);
    if (source.id !== undefined && id === undefined) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "INVALID_SOURCE_ID",
        `sources[${index}].id must be a non-empty string when present.`,
      );
    } else if (id !== undefined) {
      if (sourceIds.has(id)) {
        addDiagnostic(
          diagnostics,
          document,
          "warning",
          "DUPLICATE_SOURCE_ID",
          `Source id '${id}' is repeated within the concept.`,
        );
      }
      sourceIds.add(id);
    }
    for (const field of ["title", "author"] as const) {
      if (source[field] !== undefined && nonEmptyString(source[field]) === undefined) {
        addDiagnostic(
          diagnostics,
          document,
          "warning",
          "INVALID_SOURCE_FIELD",
          `sources[${index}].${field} must be a non-empty string when present.`,
        );
      }
    }
    if (
      source.usage_count !== undefined &&
      (typeof source.usage_count !== "number" ||
        !Number.isSafeInteger(source.usage_count) ||
        source.usage_count < 0)
    ) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "INVALID_USAGE_COUNT",
        `sources[${index}].usage_count must be a non-negative safe integer.`,
      );
    }
    if (source.last_modified !== undefined) {
      validateDatetime(diagnostics, document, `sources[${index}].last_modified`, source.last_modified);
    }
    if (source.usage_window !== undefined) {
      validateUsageWindow(diagnostics, document, `sources[${index}].usage_window`, source.usage_window);
    }
  });
}

function validateTrustAndLifecycle(diagnostics: Diagnostic[], document: ParsedDocument): void {
  const frontmatter = document.frontmatter;
  if (frontmatter.generated !== undefined) {
    if (!isRecord(frontmatter.generated)) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "INVALID_GENERATED",
        "generated must be a mapping with a 'by' actor and optional 'at' timestamp.",
      );
    } else {
      if (!isActor(frontmatter.generated.by)) {
        addDiagnostic(
          diagnostics,
          document,
          "warning",
          "INVALID_ACTOR",
          "generated.by must use <producer>/<version>, human:<id>, or process:<id>.",
        );
      }
      if (frontmatter.generated.at !== undefined) {
        validateDatetime(diagnostics, document, "generated.at", frontmatter.generated.at);
      }
    }
  }

  if (frontmatter.verified !== undefined) {
    const events = normalizeVerified(frontmatter.verified);
    if (events.length === 0) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "INVALID_VERIFIED",
        "verified must be a mapping or list of verification-event mappings.",
      );
    }
    events.forEach((event, index) => {
      if (!isRecord(event)) {
        addDiagnostic(
          diagnostics,
          document,
          "warning",
          "INVALID_VERIFICATION_EVENT",
          `verified[${index}] must be a mapping.`,
        );
        return;
      }
      if (!isActor(event.by)) {
        addDiagnostic(
          diagnostics,
          document,
          "warning",
          "INVALID_ACTOR",
          `verified[${index}].by must use the OKF actor convention.`,
        );
      }
      validateDatetime(diagnostics, document, `verified[${index}].at`, event.at);
    });
  }

  if (
    frontmatter.status !== undefined &&
    frontmatter.status !== "draft" &&
    frontmatter.status !== "stable" &&
    frontmatter.status !== "deprecated"
  ) {
    addDiagnostic(
      diagnostics,
      document,
      "warning",
      "INVALID_STATUS",
      "status must be one of draft, stable, or deprecated.",
    );
  }
  if (frontmatter.stale_after !== undefined) {
    validateDatetime(diagnostics, document, "stale_after", frontmatter.stale_after);
  }
}

function validateAttestedComputation(diagnostics: Diagnostic[], document: ParsedDocument): void {
  const frontmatter = document.frontmatter;
  if (frontmatter.type !== "Attested Computation") return;
  if (nonEmptyString(frontmatter.runtime) === undefined) {
    addDiagnostic(
      diagnostics,
      document,
      "warning",
      "ATTESTED_RUNTIME_REQUIRED",
      "Attested Computation concepts should carry a non-empty runtime.",
    );
  }

  if (frontmatter.parameters !== undefined) {
    if (!Array.isArray(frontmatter.parameters)) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "INVALID_PARAMETERS",
        "parameters must be a YAML list.",
      );
    } else {
      frontmatter.parameters.forEach((parameter, index) => {
        if (
          !isRecord(parameter) ||
          nonEmptyString(parameter.name) === undefined ||
          nonEmptyString(parameter.type) === undefined ||
          typeof parameter.required !== "boolean"
        ) {
          addDiagnostic(
            diagnostics,
            document,
            "warning",
            "INVALID_PARAMETER",
            `parameters[${index}] must contain string name/type and boolean required fields.`,
          );
        }
      });
    }
  }
  for (const field of ["computation"] as const) {
    if (frontmatter[field] !== undefined && nonEmptyString(frontmatter[field]) === undefined) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "INVALID_COMPUTATION_FIELD",
        `${field} must be a non-empty path string when present.`,
      );
    }
  }
  const computationHeading = /^#\s+Computation\s*$/im.exec(document.body);
  let inlineFenceCount = 0;
  if (computationHeading !== null) {
    const sectionStart = computationHeading.index + computationHeading[0].length;
    const remainder = document.body.slice(sectionStart);
    const nextHeading = /^#\s+/m.exec(remainder);
    const section = nextHeading === null ? remainder : remainder.slice(0, nextHeading.index);
    inlineFenceCount = Math.floor(
      [...section.matchAll(/^\s{0,3}(?:`{3,}|~{3,})[^\n]*$/gm)].length / 2,
    );
  }
  const externalComputation = nonEmptyString(frontmatter.computation);
  if (externalComputation === undefined && inlineFenceCount === 0) {
    addDiagnostic(
      diagnostics,
      document,
      "warning",
      "COMPUTATION_REQUIRED",
      "Attested Computation should provide either computation path or one fenced block under # Computation.",
    );
  } else if (externalComputation !== undefined && inlineFenceCount > 0) {
    addDiagnostic(
      diagnostics,
      document,
      "warning",
      "AMBIGUOUS_COMPUTATION",
      "Attested Computation should use either an external computation path or an inline fence, not both.",
    );
  } else if (inlineFenceCount > 1) {
    addDiagnostic(
      diagnostics,
      document,
      "warning",
      "MULTIPLE_COMPUTATIONS",
      "Inline Attested Computation should contain a single fenced code block.",
    );
  }
  for (const field of ["executor", "attester"] as const) {
    if (frontmatter[field] !== undefined) {
      const value = frontmatter[field];
      if (!isRecord(value) || nonEmptyString(value.resource) === undefined) {
        addDiagnostic(
          diagnostics,
          document,
          "warning",
          "INVALID_COMPUTATION_FIELD",
          `${field} must be a mapping with a non-empty resource when present.`,
        );
      }
    }
  }
}

function validateConcept(diagnostics: Diagnostic[], document: ParsedDocument): void {
  if (!document.hasFrontmatter) {
    addDiagnostic(
      diagnostics,
      document,
      "error",
      "MISSING_FRONTMATTER",
      "Every non-reserved OKF concept must start with YAML frontmatter.",
    );
    return;
  }
  if (diagnostics.some((diagnostic) => diagnostic.path === document.path && diagnostic.code === "INVALID_FRONTMATTER")) {
    return;
  }
  if (nonEmptyString(document.frontmatter.type) === undefined) {
    addDiagnostic(
      diagnostics,
      document,
      "error",
      "TYPE_REQUIRED",
      "Concept frontmatter must contain a non-empty type string.",
    );
  }
  for (const field of ["title", "description", "resource"] as const) {
    if (document.frontmatter[field] !== undefined && nonEmptyString(document.frontmatter[field]) === undefined) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "INVALID_RECOMMENDED_FIELD",
        `${field} should be a non-empty string when present.`,
      );
    }
  }
  if (document.frontmatter.tags !== undefined) {
    if (
      !Array.isArray(document.frontmatter.tags) ||
      document.frontmatter.tags.some((tag) => nonEmptyString(tag) === undefined)
    ) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "INVALID_TAGS",
        "tags should be a YAML list of non-empty strings.",
      );
    }
  }
  if (document.frontmatter.sources !== undefined) {
    validateSources(diagnostics, document, document.frontmatter.sources);
  }
  if (document.frontmatter.usage_window !== undefined) {
    validateUsageWindow(diagnostics, document, "usage_window", document.frontmatter.usage_window);
  }
  validateTrustAndLifecycle(diagnostics, document);
  validateAttestedComputation(diagnostics, document);
}

function validateIndex(diagnostics: Diagnostic[], document: ParsedDocument): void {
  const isRoot = document.path === "index.md";
  if (document.hasFrontmatter) {
    if (!isRoot) {
      addDiagnostic(
        diagnostics,
        document,
        "error",
        "INDEX_FRONTMATTER_NOT_ALLOWED",
        "Only the bundle-root index.md may contain frontmatter.",
      );
    } else if (
      Object.keys(document.frontmatter).length !== 1 ||
      !("okf_version" in document.frontmatter)
    ) {
      addDiagnostic(
        diagnostics,
        document,
        "error",
        "INVALID_INDEX_FRONTMATTER",
        "Root index.md frontmatter may contain only okf_version.",
      );
    }
  }
  if (isRoot && document.frontmatter.okf_version !== undefined) {
    if (typeof document.frontmatter.okf_version !== "string") {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "INVALID_OKF_VERSION",
        "okf_version should be a string.",
      );
    } else if (document.frontmatter.okf_version !== OKF_VERSION) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "UNSUPPORTED_OKF_VERSION",
        `Bundle declares OKF ${document.frontmatter.okf_version}; this consumer targets ${OKF_VERSION} and will continue best-effort.`,
      );
    }
  }
  if (!/^#\s+\S.*$/m.test(document.body)) {
    addDiagnostic(
      diagnostics,
      document,
      "error",
      "INDEX_SECTION_REQUIRED",
      "index.md must contain at least one level-one section heading.",
    );
  }
  if (!/^\s*[-*+]\s+\[[^\]]+\]\([^)]+\)/m.test(document.body)) {
    addDiagnostic(
      diagnostics,
      document,
      "warning",
      "INDEX_HAS_NO_ENTRIES",
      "index.md should enumerate concepts or subdirectories as Markdown list links.",
    );
  }
}

function validCalendarDate(value: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (match === null) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
}

function validateLog(diagnostics: Diagnostic[], document: ParsedDocument): void {
  if (document.hasFrontmatter) {
    addDiagnostic(
      diagnostics,
      document,
      "error",
      "LOG_FRONTMATTER_NOT_ALLOWED",
      "log.md must not contain frontmatter.",
    );
  }
  if (!/^#\s+\S.*$/m.test(document.body)) {
    addDiagnostic(
      diagnostics,
      document,
      "error",
      "LOG_TITLE_REQUIRED",
      "log.md must contain a level-one title.",
    );
  }
  const headings = [...document.body.matchAll(/^##\s+(.+?)\s*$/gm)].map((match) => match[1] ?? "");
  if (headings.length === 0) {
    addDiagnostic(
      diagnostics,
      document,
      "error",
      "LOG_DATE_REQUIRED",
      "log.md must group entries under ISO 8601 YYYY-MM-DD headings.",
    );
    return;
  }
  for (const heading of headings) {
    if (!validCalendarDate(heading)) {
      addDiagnostic(
        diagnostics,
        document,
        "error",
        "INVALID_LOG_DATE",
        `Log heading '${heading}' must be a valid YYYY-MM-DD date.`,
      );
    }
  }
  const validHeadings = headings.filter(validCalendarDate);
  const descending = [...validHeadings].sort().reverse();
  if (validHeadings.some((heading, index) => heading !== descending[index])) {
    addDiagnostic(
      diagnostics,
      document,
      "warning",
      "LOG_NOT_NEWEST_FIRST",
      "Log date groups should be ordered newest first.",
    );
  }
}

function validateLinks(diagnostics: Diagnostic[], bundle: KnowledgeBundle): void {
  for (const document of bundle.documents) {
    for (const link of document.links) {
      const resolution = resolveLink(bundle, document, link);
      if (resolution.kind !== "broken" && resolution.kind !== "outside") continue;
      diagnostics.push({
        severity: "warning",
        code: resolution.kind === "broken" ? "BROKEN_LINK" : "LINK_OUTSIDE_BUNDLE",
        message:
          resolution.kind === "broken"
            ? `Link target '${link.target}' does not resolve to a bundle document; OKF consumers must tolerate it.`
            : `Link target '${link.target}' resolves outside the bundle and is not projected.`,
        path: document.path,
        ...(link.line === undefined ? {} : { line: link.line + document.bodyLineOffset }),
        ...(link.column === undefined ? {} : { column: link.column }),
      });
    }
  }
}

function validateProjectorIdentities(diagnostics: Diagnostic[], bundle: KnowledgeBundle): void {
  const documentsByUid = new Map<string, ParsedDocument[]>();
  for (const document of bundle.documents) {
    if (document.kind !== "concept") continue;
    const uid = conceptUid(document.frontmatter);
    if (uid === undefined) continue;
    const documents = documentsByUid.get(uid) ?? [];
    documents.push(document);
    documentsByUid.set(uid, documents);
  }
  for (const [uid, documents] of documentsByUid) {
    if (documents.length < 2) continue;
    for (const document of documents) {
      addDiagnostic(
        diagnostics,
        document,
        "warning",
        "DUPLICATE_CONCEPT_UID",
        `Projector identity '${uid}' is used by ${documents.length} concepts; path-disambiguated IDs will be used.`,
      );
    }
  }
}

function summarize(diagnostics: Diagnostic[]): ValidationSummary {
  return diagnostics.reduce<ValidationSummary>(
    (summary, diagnostic) => {
      if (diagnostic.severity === "error") summary.errors += 1;
      else if (diagnostic.severity === "warning") summary.warnings += 1;
      else summary.info += 1;
      return summary;
    },
    { errors: 0, warnings: 0, info: 0 },
  );
}

export function validateLoadedBundle(bundle: KnowledgeBundle): BundleValidationResult {
  const diagnostics = [...bundle.diagnostics];
  if (bundle.documents.length === 0) {
    diagnostics.push({
      severity: "warning",
      code: "EMPTY_BUNDLE",
      message: "The bundle contains no Markdown documents.",
      path: ".",
    });
  }
  for (const document of bundle.documents) {
    if (document.kind === "concept") validateConcept(diagnostics, document);
    else if (document.kind === "index") validateIndex(diagnostics, document);
    else validateLog(diagnostics, document);
  }
  validateLinks(diagnostics, bundle);
  validateProjectorIdentities(diagnostics, bundle);
  diagnostics.sort(compareDiagnostics);
  const summary = summarize(diagnostics);
  return { bundle, diagnostics, summary, valid: summary.errors === 0 };
}

export async function validateBundle(rootPath: string): Promise<BundleValidationResult> {
  return validateLoadedBundle(await loadBundle(rootPath));
}
