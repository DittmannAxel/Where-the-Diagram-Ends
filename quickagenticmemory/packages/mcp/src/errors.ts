export class GatewayError extends Error {
  public constructor(
    message: string,
    public readonly code: "not_found" | "invalid_reference" | "adapter_error" | "forbidden" | "configuration_error",
  ) {
    super(message);
    this.name = "GatewayError";
  }
}

export function publicErrorMessage(error: unknown): string {
  if (error instanceof GatewayError) {
    return `${error.code}: ${error.message}`;
  }
  return "adapter_error: The knowledge source could not be read. Check server logs and adapter configuration.";
}

/** Log only an error class/code; exception messages, stacks, request bodies, and credentials stay redacted. */
export function redactedErrorForLog(error: unknown): string {
  if (error instanceof GatewayError) return `GatewayError(code=${error.code}; details=redacted)`;
  if (error instanceof Error) return `${error.name || "Error"}(details=redacted)`;
  return "UnknownError(details=redacted)";
}
