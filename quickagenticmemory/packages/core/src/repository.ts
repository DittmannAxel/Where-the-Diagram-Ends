/** Removes URL/SCP credentials before repository provenance is serialized. */
export function sanitizeRepository(value: string): string {
  const trimmed = value.trim();
  const scpLike = /^[^@\s]+@([^:]+):(.+)$/.exec(trimmed);
  if (scpLike !== null) return `git@${scpLike[1]}:${scpLike[2]}`;
  if (!/^[A-Za-z][A-Za-z\d+.-]*:\/\//.test(trimmed)) return trimmed;
  try {
    const url = new URL(trimmed);
    url.username = "";
    url.password = "";
    return url.toString().replace(/\/$/, "");
  } catch {
    return trimmed;
  }
}

/** Converts common Git remotes to a credential-free browser base URL. */
export function repositoryWebUrl(repository: string): string | undefined {
  const sanitized = sanitizeRepository(repository).replace(/\.git$/, "").replace(/\/$/, "");
  const scpLike = /^git@([^:]+):(.+)$/.exec(sanitized);
  if (scpLike !== null) return `https://${scpLike[1]}/${scpLike[2]}`;
  try {
    const url = new URL(sanitized);
    if (url.protocol === "http:" || url.protocol === "https:") return sanitized;
    if (url.protocol === "ssh:") return `https://${url.host}${url.pathname}`.replace(/\/$/, "");
  } catch {
    return undefined;
  }
  return undefined;
}
