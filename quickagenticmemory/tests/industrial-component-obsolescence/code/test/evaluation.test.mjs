import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { bm25Search, tokenize } from "../lib/bm25.mjs";
import {
  GOLD_SCHEMA_VERSION,
  QUESTIONS_SCHEMA_VERSION,
  RESULTS_SCHEMA_VERSION,
  parseGold,
  parseQuestions,
} from "../lib/contracts.mjs";
import { runEvaluation } from "../lib/evaluation.mjs";
import { buildReportData, renderStaticHtml } from "../lib/report.mjs";

const COMMIT = "0123456789abcdef0123456789abcdef01234567";
const GENERATED_AT = "2026-08-23T12:00:00Z";

const UIDS = {
  component: "urn:qam:component:iol-m8",
  distractor: "urn:qam:component:iol-m8s",
  machine: "urn:qam:machine:pkg-200-v500",
  extraMachine: "urn:qam:machine:pkg-200-v400",
  test: "urn:qam:test:fat-042",
  obsolete: "urn:qam:note:obsolete-replacement",
};

async function write(path, content) {
  await mkdir(join(path, ".."), { recursive: true });
  await writeFile(path, content, "utf8");
}

function concept({ uid, title, status = "stable", aliases = [], body, type = "Industrial Artifact" }) {
  const aliasYaml = aliases.length === 0 ? "[]" : `[${aliases.map((alias) => JSON.stringify(alias)).join(", ")}]`;
  return `---
type: ${type}
title: ${title}
description: Synthetic industrial evaluation fixture for ${title}.
status: ${status}
tags: [industrial, evaluation]
x-qam:
  uid: ${uid}
  aliases: ${aliasYaml}
generated: { by: process:evaluation-test, at: 2026-08-23T12:00:00Z }
sources:
  - id: fixture-source
    resource: urn:qam:test-source:${uid}
    title: Synthetic source
    author: process:evaluation-test
---

# ${title}

${body}
`;
}

function questionDocument() {
  return {
    schema_version: QUESTIONS_SCHEMA_VERSION,
    dataset_version: "1.0.0-test",
    questions: [
      {
        id: "impact-iol-m8",
        query: "Which FAT acceptance test and machine variant depend on the AL-8P IO-Link master?",
        terms: ["AL-8P", "acceptance test", "machine variant"],
        focus_concept_uid: UIDS.component,
        allowed_statuses: ["stable"],
        top_k: 4,
        max_hops: 2,
      },
    ],
  };
}

function goldDocument() {
  return {
    schema_version: GOLD_SCHEMA_VERSION,
    dataset_version: "1.0.0-test",
    cases: [
      {
        question_id: "impact-iol-m8",
        required_concept_uids: [UIDS.machine, UIDS.test],
        excluded_concept_uids: [UIDS.distractor, UIDS.obsolete],
        required_statuses: {
          [UIDS.machine]: "stable",
          [UIDS.test]: "stable",
        },
        required_paths: [
          [UIDS.component, UIDS.machine],
          [UIDS.component, UIDS.machine, UIDS.test],
        ],
      },
    ],
  };
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "qam-industrial-eval-"));
  const data = join(root, "data");
  const knowledge = join(data, "knowledge");
  const concepts = join(knowledge, "concepts");
  await mkdir(concepts, { recursive: true });
  await write(
    join(knowledge, "index.md"),
    `---
okf_version: "0.2"
---

# Synthetic industrial knowledge

- [IOL-M8](concepts/iol-m8.md)
- [IOL-M8S](concepts/iol-m8s.md)
- [PKG-200 V500](concepts/pkg-200-v500.md)
- [FAT-042](concepts/fat-042.md)
- [Obsolete note](concepts/obsolete-note.md)
`,
  );
  await write(
    join(concepts, "iol-m8.md"),
    concept({
      uid: UIDS.component,
      title: "IOL-M8 IO-Link Master",
      aliases: ["AL-8P", "8-port IO-Link Master", "XK8-IO"],
      type: "Component",
      body: "The current non-safety eight-port master is installed in packaging equipment.",
    }),
  );
  await write(
    join(concepts, "iol-m8s.md"),
    concept({
      uid: UIDS.distractor,
      title: "IOL-M8S Safety IO-Link Master",
      aliases: ["8-port safety IO-Link master"],
      type: "Component",
      body: "A similarly named but incompatible safety device. Do not substitute it for IOL-M8.",
    }),
  );
  await write(
    join(concepts, "pkg-200-v500.md"),
    concept({
      uid: UIDS.machine,
      title: "PKG-200 V500",
      type: "Machine Variant",
      body: "The electrical I/O map directly uses the [IOL-M8](iol-m8.md) master as AL-8P.",
    }),
  );
  await write(
    join(concepts, "fat-042.md"),
    concept({
      uid: UIDS.test,
      title: "FAT-042 IO diagnostics",
      type: "Acceptance Test",
      body: "This acceptance test verifies diagnostics for [PKG-200 V500](pkg-200-v500.md).",
    }),
  );
  await write(
    join(concepts, "obsolete-note.md"),
    concept({
      uid: UIDS.obsolete,
      title: "Withdrawn 2024 replacement note for AL-8P",
      status: "deprecated",
      type: "Service Note",
      body: "Deprecated guidance for [IOL-M8](iol-m8.md). AL-8P IOL-M8 XK8-IO replacement.",
    }),
  );
  await write(join(data, "questions", "questions.json"), `${JSON.stringify(questionDocument(), null, 2)}\n`);
  await write(join(data, "gold", "gold.json"), `${JSON.stringify(goldDocument(), null, 2)}\n`);
  return { root, data, output: join(root, "output") };
}

test("tokenization keeps IOL-M8 separate from the IOL-M8S distractor", () => {
  assert.deepEqual(tokenize("IOL-M8 vs IOL-M8S"), ["iol-m8", "vs", "iol-m8s"]);
});

test("BM25 is deterministic, exact-token aware, and status-filtered", () => {
  const chunks = [
    { id: "component#0", uid: UIDS.component, path: "component.md", title: "IOL-M8", type: "Component", status: "stable", text: "IOL-M8 AL-8P" },
    { id: "distractor#0", uid: UIDS.distractor, path: "distractor.md", title: "IOL-M8S", type: "Component", status: "stable", text: "IOL-M8S safety master" },
    { id: "old#0", uid: UIDS.obsolete, path: "old.md", title: "Old", type: "Service Note", status: "deprecated", text: "IOL-M8 IOL-M8 IOL-M8" },
  ];
  const first = bm25Search(chunks, "IOL-M8", { topK: 3, allowedStatuses: ["stable"] });
  const second = bm25Search(chunks, "IOL-M8", { topK: 3, allowedStatuses: ["stable"] });
  assert.deepEqual(first, second);
  assert.equal(first[0].uid, UIDS.component);
  assert.equal(first.some((entry) => entry.uid === UIDS.distractor), false);
  assert.equal(first.some((entry) => entry.uid === UIDS.obsolete), false);

  const componentOnly = bm25Search(chunks, "IOL-M8", {
    topK: 3,
    allowedStatuses: ["stable"],
    allowedTypes: ["Component"],
  });
  assert.ok(componentOnly.every((entry) => entry.type === "Component"));
});

test("contracts reject wrong versions and paths longer than two hops", () => {
  assert.throws(
    () => parseQuestions({ ...questionDocument(), schema_version: "wrong" }),
    /schema_version/u,
  );
  const questions = parseQuestions(questionDocument());
  const invalid = goldDocument();
  invalid.cases[0].required_paths = [[UIDS.component, UIDS.machine, UIDS.test, "urn:qam:extra"]];
  assert.throws(() => parseGold(invalid, questions), /at most two hops/u);

  const missingStatus = goldDocument();
  delete missingStatus.cases[0].required_statuses[UIDS.test];
  assert.throws(() => parseGold(missingStatus, questions), /expected status/u);
});

test("QAM resolves aliases, traverses gold paths, filters status, and pins every read", async () => {
  const setup = await fixture();
  const result = await runEvaluation({
    dataRoot: setup.data,
    outputDirectory: setup.output,
    commitSha: COMMIT,
    generatedAt: GENERATED_AT,
    repository: "https://github.com/example/industrial-evaluation",
  });

  assert.equal(result.schema_version, RESULTS_SCHEMA_VERSION);
  assert.equal(result.versions.questions_schema, QUESTIONS_SCHEMA_VERSION);
  assert.equal(result.versions.gold_schema, GOLD_SCHEMA_VERSION);
  assert.equal(result.versions.dataset_versions_match, true);
  assert.equal(result.versions.okf_version, "0.2");
  assert.equal(result.source_snapshot.commit_sha, COMMIT);
  assert.equal(result.source_snapshot.expected_commit_sha, COMMIT);
  assert.equal(result.source_snapshot.expected_commit_matched, true);
  assert.equal(result.source_snapshot.knowledge_clean_at_commit, false);
  assert.equal(result.integrity.commit.consistent, true);
  assert.equal(result.integrity.commit.mismatch_count, 0);

  const evaluated = result.cases[0];
  assert.equal(evaluated.arms.qam.focus_resolution.resolved_uid, UIDS.component);
  assert.equal(evaluated.arms.qam.focus_resolution.matched, true);
  assert.equal(evaluated.arms.qam.traversal.truncated, false);
  assert.deepEqual(evaluated.arms.qam.candidate_uids, [UIDS.machine, UIDS.test]);
  assert.equal(evaluated.arms.qam.candidate_uids.includes(UIDS.distractor), false);
  assert.equal(evaluated.arms.qam.candidate_uids.includes(UIDS.obsolete), false);
  assert.equal(evaluated.arms.qam.metrics.recall, 1);
  assert.equal(evaluated.arms.qam.metrics.precision, 1);
  assert.equal(evaluated.arms.qam.metrics.path_recall, 1);
  assert.deepEqual(evaluated.arms.qam.metrics.excluded_hits, []);
  assert.equal(evaluated.arms.qam.metrics.status_passed, true);
  assert.equal(evaluated.arms.qam.method_calls.resolve_concepts, 2);
  assert.equal(evaluated.arms.qam.method_calls.get_backlinks, 1);
  assert.ok(evaluated.arms.qam.method_calls.get_neighbors >= 2);
  assert.equal(evaluated.arms.qam.method_calls.find_path, 2);
  assert.equal(evaluated.arms.qam.method_calls.trace_provenance, 3);
  assert.equal(evaluated.arms.qam.method_calls.read_concepts, 3);
  assert.ok(evaluated.arms.qam.provenance.every((entry) => entry.source_count === 1));
  assert.ok(evaluated.arms.qam.commit_pinned_reads.every((entry) => entry.commit_sha === COMMIT));
  assert.ok(evaluated.arms.qam.commit_pinned_reads.every((entry) => entry.truncated === false));
  assert.equal(evaluated.arms.baseline.top_k_unit, "concepts-ranked-by-best-chunk");
  assert.equal(evaluated.arms.baseline.metrics.path_evaluation_available, false);
  assert.equal(evaluated.arms.baseline.metrics.path_recall, null);
  assert.equal(evaluated.arms.baseline.supported_paths, null);
  assert.equal(evaluated.arms.qam.acceptance.minimum_precision, 0.8);
  assert.equal(evaluated.arms.qam.acceptance.checks.minimum_precision, true);
  assert.equal(evaluated.arms.qam.acceptance.passed, true);
  assert.equal(evaluated.arms.baseline.candidate_uids.includes(UIDS.component), false);
  assert.deepEqual(
    new Set(evaluated.arms.baseline.candidate_uids),
    new Set([UIDS.machine, UIDS.test]),
  );
  assert.equal(evaluated.comparison.qam_acceptance_passed, true);
  assert.equal(evaluated.comparison.path_recall_delta_qam_minus_baseline, null);
  assert.equal(result.summary.qam_acceptance_passed, true);
  assert.equal(result.summary.qam_acceptance_pass_count, 1);
  assert.equal(result.summary.qam_acceptance_case_count, 1);
  assert.equal(result.summary.baseline.mean_path_recall, null);
  assert.equal(result.summary.deltas_qam_minus_baseline.mean_path_recall, null);

  const manifest = JSON.parse(await readFile(join(setup.output, "qam-artifacts", "manifest.json"), "utf8"));
  assert.equal(manifest.source.commitSha, COMMIT);
  const stored = JSON.parse(await readFile(join(setup.output, "run-results.json"), "utf8"));
  assert.deepEqual(stored.summary, result.summary);

  const report = buildReportData(result);
  const html = renderStaticHtml(report);
  assert.match(html, /no LLM answer grading/iu);
  assert.match(html, /IOL-M8/iu);
  assert.match(html, /<script>/iu);
  assert.match(html, /role="tablist"/u);
  assert.match(html, /BM25 lexical retrieval/iu);
  assert.match(html, /bounded QAM link traversal/iu);
  assert.match(html, /ACCEPTANCE PASS/u);
  assert.match(html, /RUN COMMIT LABEL/u);
  assert.match(html, /UNVERIFIED WORKTREE/u);
  assert.match(html, /QAM link-path coverage · BM25 N\/A/u);
  assert.doesNotMatch(html, /Verified immutable source snapshot/u);
  assert.match(html, /Content-Security-Policy/u);
  assert.match(html, /prefers-reduced-motion/u);
  assert.match(html, /@media print/u);
  assert.doesNotMatch(html, /<link\s/iu);

  const verifiedHtml = renderStaticHtml({
    ...report,
    source_snapshot: {
      ...report.source_snapshot,
      knowledge_tracked: true,
      knowledge_clean_at_commit: true,
    },
  });
  assert.match(verifiedHtml, /PINNED COMMIT/u);
  assert.match(verifiedHtml, /REPRODUCIBLE/u);
  assert.match(verifiedHtml, /Verified immutable source snapshot/u);
});

test("query terms must be visible in the question instead of carrying hidden answer hints", async () => {
  const setup = await fixture();
  const questionsPath = join(setup.data, "questions", "questions.json");
  const questions = JSON.parse(await readFile(questionsPath, "utf8"));
  questions.questions[0].terms.push("PKG-200 V500");
  await writeFile(questionsPath, `${JSON.stringify(questions, null, 2)}\n`, "utf8");

  await assert.rejects(
    runEvaluation({
      dataRoot: setup.data,
      outputDirectory: setup.output,
      commitSha: COMMIT,
      generatedAt: GENERATED_AT,
      repository: "example/industrial-evaluation",
    }),
    /must be derived from its query text/u,
  );
});

test("full recall and path coverage do not pass when precision is below the declared minimum", async () => {
  const setup = await fixture();
  await write(
    join(setup.data, "knowledge", "concepts", "pkg-200-v400.md"),
    concept({
      uid: UIDS.extraMachine,
      title: "PKG-200 V400",
      type: "Machine Variant",
      body: "This separate delivered variant also links to [IOL-M8](iol-m8.md) but is outside the requested gold set.",
    }),
  );

  const result = await runEvaluation({
    dataRoot: setup.data,
    outputDirectory: setup.output,
    commitSha: COMMIT,
    generatedAt: GENERATED_AT,
    repository: "example/industrial-evaluation",
  });
  const evaluated = result.cases[0];
  assert.equal(evaluated.arms.qam.metrics.recall, 1);
  assert.equal(evaluated.arms.qam.metrics.path_recall, 1);
  assert.ok(evaluated.arms.qam.metrics.precision < 0.8);
  assert.equal(evaluated.arms.qam.acceptance.checks.minimum_precision, false);
  assert.equal(evaluated.arms.qam.acceptance.passed, false);
  assert.equal(evaluated.comparison.qam_acceptance_passed, false);
  assert.equal(result.summary.qam_acceptance_passed, false);
  assert.equal(result.summary.qam_acceptance_pass_count, 0);
});

test("clean-commit requirement remains explicit and machine-readable", async () => {
  const setup = await fixture();
  const result = await runEvaluation({
    dataRoot: setup.data,
    outputDirectory: setup.output,
    commitSha: COMMIT,
    generatedAt: GENERATED_AT,
    repository: "example/industrial-evaluation",
    requireCleanCommit: true,
  });
  assert.equal(result.integrity.clean_commit_required, true);
  assert.equal(result.integrity.clean_commit_requirement_passed, false);
  assert.equal(result.summary.qam_acceptance_passed, true);
});

test("wrong status and expected commit are surfaced instead of silently accepted", async () => {
  const setup = await fixture();
  const goldPath = join(setup.data, "gold", "gold.json");
  const gold = JSON.parse(await readFile(goldPath, "utf8"));
  gold.expected_commit_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  gold.cases[0].required_statuses[UIDS.machine] = "deprecated";
  await writeFile(goldPath, `${JSON.stringify(gold, null, 2)}\n`, "utf8");

  const result = await runEvaluation({
    dataRoot: setup.data,
    outputDirectory: setup.output,
    commitSha: COMMIT,
    generatedAt: GENERATED_AT,
    repository: "example/industrial-evaluation",
  });
  assert.equal(result.source_snapshot.expected_commit_matched, false);
  assert.equal(result.cases[0].arms.qam.metrics.status_passed, false);
  assert.equal(
    result.cases[0].arms.qam.metrics.status_checks.find((check) => check.uid === UIDS.machine)?.passed,
    false,
  );
  assert.equal(result.summary.qam_acceptance_passed, false);
});
