#!/usr/bin/env node
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

import { runEvaluation } from "./lib/evaluation.mjs";
import { atomicWriteJson, atomicWriteText } from "./lib/io.mjs";
import { buildReportData, renderStaticHtml } from "./lib/report.mjs";

const SCRIPT_DIRECTORY = dirname(fileURLToPath(import.meta.url));

function usage() {
  return `Industrial component-obsolescence A/B evaluation

Usage:
  node runner.mjs [options]

Options:
  --data PATH                 Data root (default: ../data)
  --output PATH               Evidence output (default: ../screens/evidence/latest)
  --commit SHA                Full 40/64-character Git commit (default: HEAD)
  --repository URL_OR_SLUG    Public repository identity (default: sanitized origin)
  --generated-at ISO_DATETIME Deterministic projection time (default: commit timestamp)
  --require-clean-commit      Fail unless data/knowledge is tracked and clean at SHA
  --help                      Show this help
`;
}

function parseArguments(argv) {
  const parsed = {
    dataRoot: resolve(SCRIPT_DIRECTORY, "../data"),
    outputDirectory: resolve(SCRIPT_DIRECTORY, "../screens/evidence/latest"),
    requireCleanCommit: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help") return { help: true };
    if (argument === "--require-clean-commit") {
      parsed.requireCleanCommit = true;
      continue;
    }
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new TypeError(`Option '${argument}' requires a value`);
    }
    index += 1;
    if (argument === "--data") parsed.dataRoot = resolve(value);
    else if (argument === "--output") parsed.outputDirectory = resolve(value);
    else if (argument === "--commit") parsed.commitSha = value;
    else if (argument === "--repository") parsed.repository = value;
    else if (argument === "--generated-at") parsed.generatedAt = value;
    else throw new TypeError(`Unknown option '${argument}'`);
  }
  return parsed;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help === true) {
    process.stdout.write(usage());
    return;
  }

  const result = await runEvaluation(options);
  const report = buildReportData(result);
  await atomicWriteJson(join(options.outputDirectory, "report-data.json"), report);
  await atomicWriteText(join(options.outputDirectory, "report.html"), renderStaticHtml(report));

  const summary = {
    result: join(options.outputDirectory, "run-results.json"),
    report: join(options.outputDirectory, "report.html"),
    commit_sha: result.source_snapshot.commit_sha,
    knowledge_clean_at_commit: result.source_snapshot.knowledge_clean_at_commit,
    baseline_mean_recall: result.summary.baseline.mean_recall,
    baseline_mean_precision: result.summary.baseline.mean_precision,
    qam_mean_recall: result.summary.qam.mean_recall,
    qam_mean_precision: result.summary.qam.mean_precision,
    qam_mean_path_recall: result.summary.qam.mean_path_recall,
    qam_excluded_hit_count: result.summary.qam.excluded_hit_count,
    qam_acceptance_passed: result.summary.qam_acceptance_passed,
    qam_acceptance_pass_count: result.summary.qam_acceptance_pass_count,
    qam_acceptance_case_count: result.summary.qam_acceptance_case_count,
  };
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);

  if (!result.integrity.clean_commit_requirement_passed) process.exitCode = 3;
  else if (!result.summary.qam_acceptance_passed) process.exitCode = 2;
}

main().catch((error) => {
  const detail = error instanceof Error ? error.stack ?? error.message : String(error);
  process.stderr.write(`Evaluation failed: ${detail}\n`);
  process.exitCode = 1;
});
