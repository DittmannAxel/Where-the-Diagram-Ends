import { GatewayError } from "../errors.js";

export function validateRemoteUrl(value: string, allowInsecureLocalhost = false): URL {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new GatewayError("Adapter URL is not a valid absolute URL.", "configuration_error");
  }
  const local = url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "[::1]";
  if (url.protocol !== "https:" && !(allowInsecureLocalhost && local && url.protocol === "http:")) {
    throw new GatewayError("Remote adapter URLs must use HTTPS (HTTP is allowed only for explicit localhost tests).", "configuration_error");
  }
  if (url.username !== "" || url.password !== "") {
    throw new GatewayError("Adapter URLs must not contain credentials.", "configuration_error");
  }
  return url;
}

export async function fetchWithTimeout(
  url: URL,
  init: RequestInit,
  timeoutMs: number,
  label: string,
): Promise<Response> {
  const response = await fetchResponseWithTimeout(url, init, timeoutMs, label);
  if (!response.ok) {
    throw new GatewayError(`${label} returned HTTP ${response.status}.`, "adapter_error");
  }
  return response;
}

/** Fetch with redirect denial and timeout, but leave HTTP status handling to callers that need bounded retry logic. */
export async function fetchResponseWithTimeout(
  url: URL,
  init: RequestInit,
  timeoutMs: number,
  label: string,
): Promise<Response> {
  try {
    const response = await fetch(url, { ...init, redirect: "error", signal: AbortSignal.timeout(timeoutMs) });
    return response;
  } catch (error) {
    if (error instanceof GatewayError) throw error;
    throw new GatewayError(`${label} could not be reached.`, "adapter_error");
  }
}

export function bearerHeaders(token: string | undefined): Record<string, string> {
  return token === undefined || token === "" ? {} : { Authorization: `Bearer ${token}` };
}
