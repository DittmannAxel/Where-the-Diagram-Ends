#!/usr/bin/env node

import { pathToFileURL } from "node:url";

import { writeProjection } from "./exporter.js";
import { discoverGitMetadata } from "./git.js";
import { projectValidatedBundle, ProjectionValidationError } from "./projector.js";
import type { Diagnostic, GitMetadata } from "./types.js";
import { validateBundle } from "./validator.js";

const VERSION = "0.1.0";

export interface CliIo {
  stdout: (value: string) => void;
  stderr: (value: string) => void;
}

interface ParsedArguments {
  command?: string;
  positionals: string[];
  flags: Map<string, string | true>;
}

const VALUE_FLAGS = new Set([
  "--output",
  "-o",
  "--git-sha",
  "--generated-at",
  "--repository",
  "--path-in-repository",
  "--source-base-url",
]);
const BOOLEAN_FLAGS = new Set(["--json", "--strict", "--help", "-h", "--version", "-v"]);

const USAGE = `Quick Agentic Memory core

Usage:
  qam-core validate <bundle> [--json] [--strict]
  qam-core project <bundle> --output <directory> [metadata options] [--strict]

Metadata options (auto-discovered from Git when omitted):
  --git-sha <sha>
  --generated-at <ISO-8601 commit timestamp>
  --repository <Git remote or URL>
  --path-in-repository <bundle path>
  --source-base-url <URL prefix for source documents>

Validation follows OKF v0.2's permissive conformance rules. --strict also fails on warnings.
`;

function parseArguments(argv: string[]): ParsedArguments {
  const flags = new Map<string, string | true>();
  const positionals: string[] = [];
  let command: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === undefined) continue;
    if (argument.startsWith("--") && argument.includes("=")) {
      const separator = argument.indexOf("=");
      const name = argument.slice(0, separator);
      const value = argument.slice(separator + 1);
      if (!VALUE_FLAGS.has(name)) throw new Error(`Unknown option: ${name}`);
      if (value.length === 0) throw new Error(`Option ${name} requires a value.`);
      flags.set(name, value);
      continue;
    }
    if (VALUE_FLAGS.has(argument)) {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith("-")) {
        throw new Error(`Option ${argument} requires a value.`);
      }
      flags.set(argument, value);
      index += 1;
      continue;
    }
    if (BOOLEAN_FLAGS.has(argument)) {
      flags.set(argument, true);
      continue;
    }
    if (argument.startsWith("-")) throw new Error(`Unknown option: ${argument}`);
    if (command === undefined) command = argument;
    else positionals.push(argument);
  }

  return { ...(command === undefined ? {} : { command }), positionals, flags };
}

function valueFlag(parsed: ParsedArguments, name: string, alias?: string): string | undefined {
  const value = parsed.flags.get(name) ?? (alias === undefined ? undefined : parsed.flags.get(alias));
  return typeof value === "string" ? value : undefined;
}

function formatDiagnostic(diagnostic: Diagnostic): string {
  const location =
    diagnostic.line === undefined
      ? diagnostic.path
      : `${diagnostic.path}:${diagnostic.line}${diagnostic.column === undefined ? "" : `:${diagnostic.column}`}`;
  return `${diagnostic.severity.toLocaleUpperCase("en-US")} ${location} [${diagnostic.code}] ${diagnostic.message}`;
}

function printValidation(
  io: CliIo,
  result: Awaited<ReturnType<typeof validateBundle>>,
  json: boolean,
  strict: boolean,
): void {
  if (json) {
    io.stdout(
      `${JSON.stringify(
        {
          valid: result.valid,
          strictValid: result.valid && (!strict || result.summary.warnings === 0),
          summary: result.summary,
          diagnostics: result.diagnostics,
        },
        null,
        2,
      )}\n`,
    );
    return;
  }
  for (const diagnostic of result.diagnostics) io.stdout(`${formatDiagnostic(diagnostic)}\n`);
  io.stdout(
    `Validation: ${result.summary.errors} error(s), ${result.summary.warnings} warning(s), ${result.summary.info} info.\n`,
  );
}

function metadataOverrides(parsed: ParsedArguments): Partial<GitMetadata> {
  const gitSha = valueFlag(parsed, "--git-sha");
  const generatedAt = valueFlag(parsed, "--generated-at");
  const repository = valueFlag(parsed, "--repository");
  const pathInRepository = valueFlag(parsed, "--path-in-repository");
  return {
    ...(gitSha === undefined ? {} : { gitSha }),
    ...(generatedAt === undefined ? {} : { generatedAt }),
    ...(repository === undefined ? {} : { repository }),
    ...(pathInRepository === undefined ? {} : { pathInRepository }),
  };
}

export async function runCli(
  argv: string[],
  io: CliIo = {
    stdout: (value) => process.stdout.write(value),
    stderr: (value) => process.stderr.write(value),
  },
): Promise<number> {
  try {
    const parsed = parseArguments(argv);
    if (parsed.flags.has("--version") || parsed.flags.has("-v")) {
      io.stdout(`${VERSION}\n`);
      return 0;
    }
    if (
      parsed.flags.has("--help") ||
      parsed.flags.has("-h") ||
      parsed.command === undefined
    ) {
      io.stdout(USAGE);
      return 0;
    }
    if (parsed.positionals.length > 1) throw new Error("Expected one bundle path.");
    const bundlePath = parsed.positionals[0] ?? ".";
    const strict = parsed.flags.has("--strict");

    if (parsed.command === "validate") {
      const allowed = new Set(["--json", "--strict"]);
      for (const flag of parsed.flags.keys()) {
        if (!allowed.has(flag)) throw new Error(`Option ${flag} is not valid for the validate command.`);
      }
      const result = await validateBundle(bundlePath);
      printValidation(io, result, parsed.flags.has("--json"), strict);
      return result.valid && (!strict || result.summary.warnings === 0) ? 0 : 1;
    }

    if (parsed.command === "project") {
      if (parsed.flags.has("--json")) throw new Error("--json is only valid for the validate command.");
      const outputDirectory = valueFlag(parsed, "--output", "-o");
      if (outputDirectory === undefined) throw new Error("The project command requires --output <directory>.");
      const validation = await validateBundle(bundlePath);
      if (!validation.valid || (strict && validation.summary.warnings > 0)) {
        printValidation(io, validation, false, strict);
        return 1;
      }
      const metadata = discoverGitMetadata(bundlePath, metadataOverrides(parsed));
      const sourceBaseUrl = valueFlag(parsed, "--source-base-url");
      const projection = projectValidatedBundle(validation, {
        ...metadata,
        ...(sourceBaseUrl === undefined ? {} : { sourceBaseUrl }),
        strict,
      });
      const files = await writeProjection(projection, outputDirectory);
      io.stdout(
        `Projected ${projection.manifest.counts.nodes} node(s) and ${projection.manifest.counts.edges} edge(s).\n`,
      );
      for (const file of files) io.stdout(`${file}\n`);
      return 0;
    }

    throw new Error(`Unknown command: ${parsed.command}`);
  } catch (error) {
    if (error instanceof ProjectionValidationError) {
      printValidation(io, error.validation, false, false);
      return 1;
    }
    io.stderr(`${error instanceof Error ? error.message : String(error)}\n`);
    return 2;
  }
}

const invokedPath = process.argv[1];
if (invokedPath !== undefined && import.meta.url === pathToFileURL(invokedPath).href) {
  process.exitCode = await runCli(process.argv.slice(2));
}
