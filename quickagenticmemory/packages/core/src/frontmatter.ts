import { compareText, normalizeTerm } from "./hash.js";
import { isIsoDatetimeWithOffset } from "./time.js";
import type { Frontmatter } from "./types.js";

export interface OkfSource {
  id?: string;
  resource: string;
  title?: string;
  author?: string;
  usageCount?: number;
  lastModified?: string;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function nonEmptyString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length === 0 ? undefined : trimmed;
}

export function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => nonEmptyString(item))
    .filter((item): item is string => item !== undefined);
}

function extension(frontmatter: Frontmatter, key: "x-qam" | "x-kg"): Record<string, unknown> {
  const value = frontmatter[key];
  return isRecord(value) ? value : {};
}

export function conceptUid(frontmatter: Frontmatter): string | undefined {
  return (
    nonEmptyString(extension(frontmatter, "x-qam").uid) ??
    nonEmptyString(extension(frontmatter, "x-kg").uid) ??
    nonEmptyString(frontmatter.uid)
  );
}

export function conceptAliases(frontmatter: Frontmatter): string[] {
  const candidates = [
    ...stringList(frontmatter.aliases),
    ...stringList(extension(frontmatter, "x-qam").aliases),
    ...stringList(extension(frontmatter, "x-kg").aliases),
  ];
  const byNormalizedValue = new Map<string, string>();

  for (const alias of candidates.sort(compareText)) {
    const normalized = normalizeTerm(alias);
    if (normalized.length > 0 && !byNormalizedValue.has(normalized)) {
      byNormalizedValue.set(normalized, alias);
    }
  }

  return [...byNormalizedValue.values()].sort(compareText);
}

export function conceptTags(frontmatter: Frontmatter): string[] {
  const tags = stringList(frontmatter.tags).sort(compareText);
  const byNormalizedValue = new Map<string, string>();
  for (const tag of tags) {
    const normalized = normalizeTerm(tag);
    if (normalized.length > 0 && !byNormalizedValue.has(normalized)) byNormalizedValue.set(normalized, tag);
  }
  return [...byNormalizedValue.values()].sort(compareText);
}

export function okfSources(frontmatter: Frontmatter): OkfSource[] {
  if (!Array.isArray(frontmatter.sources)) return [];

  const sources: OkfSource[] = [];
  for (const candidate of frontmatter.sources) {
    if (!isRecord(candidate)) continue;
    const resource = nonEmptyString(candidate.resource);
    if (resource === undefined) continue;
    const id = nonEmptyString(candidate.id);
    const title = nonEmptyString(candidate.title);
    const author = nonEmptyString(candidate.author);
    const usageCount =
      typeof candidate.usage_count === "number" &&
      Number.isSafeInteger(candidate.usage_count) &&
      candidate.usage_count >= 0
        ? candidate.usage_count
        : undefined;
    const lastModifiedCandidate = nonEmptyString(candidate.last_modified);
    const lastModified = isIsoDatetimeWithOffset(lastModifiedCandidate)
      ? lastModifiedCandidate
      : undefined;
    sources.push({
      resource,
      ...(id === undefined ? {} : { id }),
      ...(title === undefined ? {} : { title }),
      ...(author === undefined ? {} : { author }),
      ...(usageCount === undefined ? {} : { usageCount }),
      ...(lastModified === undefined ? {} : { lastModified }),
    });
  }

  return sources.sort((left, right) => {
    const byResource = compareText(left.resource, right.resource);
    if (byResource !== 0) return byResource;
    return compareText(left.id ?? "", right.id ?? "");
  });
}

export function conceptStatus(frontmatter: Frontmatter): "draft" | "stable" | "deprecated" {
  if (frontmatter.status === "draft" || frontmatter.status === "deprecated") return frontmatter.status;
  return "stable";
}
