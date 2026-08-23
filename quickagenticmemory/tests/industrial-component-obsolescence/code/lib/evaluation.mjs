import { join } from "node:path";

import {
  conceptUid,
  projectBundle,
  writeProjection,
} from "../../../../packages/core/dist/index.js";
import {
  LocalMarkdownContentAdapter,
  MemoryGraphAdapter,
} from "../../../../packages/mcp/dist/index.js";
import { KnowledgeService } from "../../../../packages/mcp/dist/knowledge-service.js";

import { bm25Search, chunkDocuments } from "./bm25.mjs";
import {
  GOLD_SCHEMA_VERSION,
  QUESTIONS_SCHEMA_VERSION,
  RESULTS_SCHEMA_VERSION,
  parseGold,
  parseQuestions,
} from "./contracts.mjs";
import { atomicWriteJson, dataPaths, gitSnapshot, readJson } from "./io.mjs";

const EDGE_TYPES = ["LINKS_TO"];
const MINIMUM_QAM_PRECISION = 0.8;
const REQUESTED_TYPE_RULES = [
  ["Machine Variant", [/^variants?$/u, /\bmachine variants?\b/u]],
  ["I/O Mapping", [/\bi o mappings?\b/u]],
  [
    "PLC Function Block",
    [
      /^diagnostic blocks?$/u,
      /\bplc diagnostic blocks?\b/u,
      /\bdiagnostic function blocks?\b/u,
    ],
  ],
  ["Parameter Set", [/\bparameter sets?\b/u]],
  ["Acceptance Test", [/^(?:fat|sat)$/u, /\bacceptance tests?\b/u]],
  ["Service Bulletin", [/\bservice bulletins?\b/u]],
  ["Change Request", [/\bcontrolled change\b/u, /\bchange requests?\b/u]],
];

function compareText(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function round(value) {
  return Number(value.toFixed(6));
}

function average(values) {
  return values.length === 0 ? 0 : round(values.reduce((sum, value) => sum + value, 0) / values.length);
}

function orderedUnique(values) {
  return [...new Set(values)];
}

function normalizeQueryText(value) {
  return String(value)
    .normalize("NFKC")
    .toLocaleLowerCase("en-US")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim()
    .replace(/\s+/gu, " ");
}

function requestedTypesFor(question) {
  const normalizedQuery = normalizeQueryText(question.query);
  const normalizedTerms = question.terms.map((term) => normalizeQueryText(term));
  for (const [index, term] of normalizedTerms.entries()) {
    if (term.length === 0 || !normalizedQuery.includes(term)) {
      throw new TypeError(
        `Question '${question.id}' term '${question.terms[index]}' must be derived from its query text`,
      );
    }
  }

  const requestedTypes = REQUESTED_TYPE_RULES.filter(([_type, patterns]) =>
    normalizedTerms.some((term) => patterns.some((pattern) => pattern.test(term))),
  ).map(([type]) => type);
  if (requestedTypes.length === 0) {
    throw new TypeError(
      `Question '${question.id}' must include at least one query-derived result-type term`,
    );
  }
  return requestedTypes;
}

function metadataForProjection(projection) {
  const documents = projection.validation.bundle.documents.filter((document) => document.kind === "concept");
  const nodeByPath = new Map(
    projection.graph.nodes
      .filter((node) => node.kind === "Concept")
      .map((node) => [node.path, node]),
  );
  const metadataByPath = new Map();
  const metadataByUid = new Map();
  const uidByNodeId = new Map();

  for (const document of documents) {
    const node = nodeByPath.get(document.path);
    if (node === undefined) throw new Error(`Projected concept is missing for '${document.path}'`);
    const uid = conceptUid(document.frontmatter) ?? document.conceptId ?? document.path;
    if (metadataByUid.has(uid)) throw new Error(`Knowledge bundle has duplicate concept UID '${uid}'`);
    const metadata = {
      uid,
      node_id: node.id,
      path: node.path,
      title: node.title,
      type: node.type,
      status: node.status,
      aliases: node.aliases,
      tags: node.tags,
      commit_sha: node.commitSha,
      content_hash: node.contentHash,
    };
    metadataByPath.set(document.path, metadata);
    metadataByUid.set(uid, metadata);
    uidByNodeId.set(node.id, uid);
  }

  return { documents, metadataByPath, metadataByUid, uidByNodeId };
}

function conceptRankingFromChunks(rankedChunks, focusUid, topK) {
  const bestByUid = new Map();
  for (const chunk of rankedChunks) {
    if (chunk.uid === focusUid) continue;
    if (!bestByUid.has(chunk.uid)) {
      bestByUid.set(chunk.uid, {
        uid: chunk.uid,
        path: chunk.path,
        title: chunk.title,
        type: chunk.type,
        status: chunk.status,
        best_score: chunk.score,
        best_chunk_id: chunk.id,
        matched_tokens: chunk.matched_tokens,
      });
    }
  }
  const rankedConcepts = [...bestByUid.values()].slice(0, topK);
  return {
    ranked_concepts: rankedConcepts,
    candidate_uids: rankedConcepts.map((entry) => entry.uid),
  };
}

function metricFor(retrievedUids, goldCase, statusByUid, supportedPaths) {
  const retrieved = orderedUnique(retrievedUids);
  const required = new Set(goldCase.required_concept_uids);
  const excluded = new Set(goldCase.excluded_concept_uids);
  const truePositives = retrieved.filter((uid) => required.has(uid));
  const missed = [...required].filter((uid) => !retrieved.includes(uid));
  const excludedHits = retrieved.filter((uid) => excluded.has(uid));
  const falsePositives = retrieved.filter((uid) => !required.has(uid));
  const recall = required.size === 0 ? 1 : truePositives.length / required.size;
  const precision = retrieved.length === 0 ? 0 : truePositives.length / retrieved.length;
  const f1 = recall + precision === 0 ? 0 : (2 * recall * precision) / (recall + precision);
  const statusChecks = Object.entries(goldCase.required_statuses)
    .sort(([left], [right]) => compareText(left, right))
    .map(([uid, expected]) => ({
      uid,
      expected,
      actual: statusByUid.get(uid) ?? null,
      retrieved: retrieved.includes(uid),
      passed: statusByUid.get(uid) === expected && retrieved.includes(uid),
    }));
  const pathEvaluationAvailable = supportedPaths !== null;
  const pathChecks = pathEvaluationAvailable
    ? goldCase.required_paths.map((requiredPath) => {
        const matched = supportedPaths.some(
          (candidate) =>
            candidate.length === requiredPath.length &&
            candidate.every((uid, index) => uid === requiredPath[index]),
        );
        return { required_uid_sequence: requiredPath, supported: matched };
      })
    : [];

  return {
    retrieved_count: retrieved.length,
    required_count: required.size,
    true_positive_uids: truePositives,
    false_positive_uids: falsePositives,
    missed_required_uids: missed,
    excluded_hits: excludedHits,
    recall: round(recall),
    precision: round(precision),
    f1: round(f1),
    status_checks: statusChecks,
    status_passed: statusChecks.every((check) => check.passed),
    path_evaluation_available: pathEvaluationAvailable,
    path_checks: pathChecks,
    path_recall:
      !pathEvaluationAvailable
        ? null
        : pathChecks.length === 0
        ? 1
        : round(pathChecks.filter((check) => check.supported).length / pathChecks.length),
  };
}

async function runBaseline(question, chunks, requestedTypes) {
  const rankedChunks = bm25Search(chunks, question.terms.join("\n"), {
    topK: chunks.length,
    allowedStatuses: question.allowed_statuses,
    allowedTypes: requestedTypes,
  });
  const concepts = conceptRankingFromChunks(
    rankedChunks,
    question.focus_concept_uid,
    question.top_k,
  );
  const selectedUids = new Set(concepts.candidate_uids);
  return {
    method: "local-bm25-markdown-chunks",
    method_version: "1.1",
    generated_answer: false,
    top_k_unit: "concepts-ranked-by-best-chunk",
    top_k: question.top_k,
    requested_types: requestedTypes,
    chunking: { max_characters: 1_000, overlap_characters: 160, metadata_attached: true },
    ranked_chunks: rankedChunks
      .filter((chunk) => selectedUids.has(chunk.uid))
      .slice(0, question.top_k)
      .map(({ text: _text, ...evidence }) => evidence),
    ...concepts,
    supported_paths: null,
  };
}

async function runQam(question, graph, knowledgeService, metadata, requestedTypes) {
  const allowedStatuses = new Set(question.allowed_statuses);
  const requestedTypeSet = new Set(requestedTypes);
  // `terms[0]` is the entity mention to resolve. Remaining terms describe the
  // requested impact slice (for example PKG-200, FAT, or current bulletin).
  // Keeping these two steps separate prevents a generic task term from becoming
  // the graph traversal root merely because it matched more fields.
  const resolution = await graph.resolveConcepts({
    terms: [question.terms[0]],
    limit: 20,
    offset: 0,
  });
  const contextualResolution = await graph.resolveConcepts({
    terms: question.terms,
    limit: 100,
    offset: 0,
  });
  const relevanceByNodeId = new Map(
    contextualResolution.items.map((item) => [item.concept.id, item]),
  );
  const eligibleResolution = resolution.items.filter((item) => allowedStatuses.has(item.concept.status));
  const focus = eligibleResolution[0]?.concept;
  const focusUid = focus === undefined ? null : (metadata.uidByNodeId.get(focus.id) ?? null);
  if (focus === undefined || focusUid === null) {
    return {
      method: "qam-core-plus-mcp-graph-tools",
      method_version: "1.0",
      generated_answer: false,
      top_k_unit: "concepts",
      top_k: question.top_k,
      requested_types: requestedTypes,
      focus_resolution: {
        expected_uid: question.focus_concept_uid,
        resolved_uid: focusUid,
        matched: false,
        candidates: resolution.items.map((item) => ({
          uid: metadata.uidByNodeId.get(item.concept.id) ?? null,
          score: item.score,
          matched_terms: item.matched_terms,
          matched_fields: item.matched_fields,
        })),
      },
      direct_backlinks: [],
      traversal: {
        direction: "both",
        edge_types: EDGE_TYPES,
        max_hops: question.max_hops,
        reachable_before_top_k: 0,
        hard_limit: 100,
        truncated: false,
      },
      ranked_concepts: [],
      candidate_uids: [],
      paths: [],
      supported_paths: [],
      provenance: [],
      commit_pinned_reads: [],
      method_calls: {
        resolve_concepts: 2,
        get_backlinks: 0,
        get_neighbors: 0,
        find_path: 0,
        trace_provenance: 0,
        read_concepts: 0,
      },
    };
  }

  const directBacklinksPage = await graph.getBacklinks({
    conceptId: focus.id,
    edgeTypes: EDGE_TYPES,
    limit: 100,
    offset: 0,
  });
  const directBacklinks = directBacklinksPage.items.map((item) => ({
    uid: metadata.uidByNodeId.get(item.source.id) ?? null,
    title: item.source.title,
    status: item.source.status,
    edge_type: item.edge.type,
  }));

  const visited = new Set([focus.id]);
  const reachableCandidates = [];
  let frontier = [focus.id];
  let neighborCalls = 0;
  let traversalTruncated = directBacklinksPage.has_more;
  for (let distance = 1; distance <= question.max_hops && frontier.length > 0; distance += 1) {
    const nextFrontier = [];
    for (const conceptId of [...frontier].sort(compareText)) {
      const neighbors = await graph.getNeighbors({
        conceptId,
        maxHops: 1,
        direction: "both",
        edgeTypes: EDGE_TYPES,
        limit: 100,
      });
      neighborCalls += 1;
      traversalTruncated ||= neighbors.truncated;
      for (const neighbor of neighbors.nodes) {
        if (visited.has(neighbor.concept.id)) continue;
        visited.add(neighbor.concept.id);
        if (!allowedStatuses.has(neighbor.concept.status)) continue;
        const uid = metadata.uidByNodeId.get(neighbor.concept.id);
        if (uid === undefined) continue;
        nextFrontier.push(neighbor.concept.id);
        const conceptMetadata = metadata.metadataByUid.get(uid);
        if (conceptMetadata === undefined || !requestedTypeSet.has(conceptMetadata.type)) continue;
        if (reachableCandidates.length >= 100) {
          traversalTruncated = true;
          continue;
        }
        const relevance = relevanceByNodeId.get(neighbor.concept.id);
        reachableCandidates.push({
          uid,
          node_id: neighbor.concept.id,
          path: neighbor.concept.path,
          title: neighbor.concept.title,
          type: conceptMetadata.type,
          status: neighbor.concept.status,
          distance,
          relevance_score: relevance?.score ?? 0,
          matched_terms: relevance?.matched_terms ?? [],
          matched_fields: relevance?.matched_fields ?? [],
        });
      }
    }
    frontier = nextFrontier;
  }

  const candidates = reachableCandidates
    .sort(
      (left, right) =>
        right.matched_terms.length - left.matched_terms.length ||
        right.relevance_score - left.relevance_score ||
        left.distance - right.distance ||
        compareText(left.title, right.title) ||
        compareText(left.uid, right.uid),
    )
    .slice(0, question.top_k);

  const paths = [];
  for (const candidate of candidates) {
    const result = await graph.findPath({
      fromId: focus.id,
      toId: candidate.node_id,
      maxHops: question.max_hops,
      direction: "both",
      edgeTypes: EDGE_TYPES,
    });
    paths.push({
      target_uid: candidate.uid,
      found: result.found,
      hop_count: result.hop_count,
      uid_sequence: result.steps.map((step) => metadata.uidByNodeId.get(step.concept.id) ?? "<unknown>"),
      edge_sequence: result.steps.slice(1).map((step) => step.via_edge?.type ?? null),
    });
  }

  const evidenceConceptIds = [focus.id, ...candidates.map((candidate) => candidate.node_id)];
  const provenance = [];
  const reads = [];
  for (const conceptId of evidenceConceptIds) {
    const uid = metadata.uidByNodeId.get(conceptId);
    const traced = await graph.traceProvenance(conceptId);
    provenance.push({
      uid,
      concept_commit_sha: traced.concept.commitSha,
      snapshot_commit_sha: traced.snapshot.commitSha,
      source_count: traced.source_nodes.length,
      source_resources: traced.source_nodes.map((source) => source.resource),
    });
    const read = await knowledgeService.readConcepts(
      [conceptId],
      traced.snapshot.commitSha,
      50_000,
    );
    const document = read.documents[0];
    if (document === undefined) throw new Error(`Commit-pinned read returned no document for '${conceptId}'`);
    reads.push({
      uid,
      path: document.document.path,
      commit_sha: document.document.commit_sha,
      content_hash: document.concept.contentHash,
      original_characters: document.original_characters,
      truncated: document.truncated,
    });
  }

  return {
    method: "qam-core-plus-mcp-graph-tools",
    method_version: "1.0",
    generated_answer: false,
    top_k_unit: "concepts",
    top_k: question.top_k,
    requested_types: requestedTypes,
    focus_resolution: {
      expected_uid: question.focus_concept_uid,
      resolved_uid: focusUid,
      matched: focusUid === question.focus_concept_uid,
      candidates: resolution.items.map((item) => ({
        uid: metadata.uidByNodeId.get(item.concept.id) ?? null,
        score: item.score,
        matched_terms: item.matched_terms,
        matched_fields: item.matched_fields,
      })),
    },
    direct_backlinks: directBacklinks,
    traversal: {
      direction: "both",
      edge_types: EDGE_TYPES,
      max_hops: question.max_hops,
      reachable_before_top_k: reachableCandidates.length,
      hard_limit: 100,
      truncated: traversalTruncated,
    },
    ranked_concepts: candidates,
    candidate_uids: candidates.map((candidate) => candidate.uid),
    paths,
    supported_paths: paths.filter((path) => path.found).map((path) => path.uid_sequence),
    provenance,
    commit_pinned_reads: reads,
    method_calls: {
      resolve_concepts: 2,
      get_backlinks: 1,
      get_neighbors: neighborCalls,
      find_path: candidates.length,
      trace_provenance: evidenceConceptIds.length,
      read_concepts: evidenceConceptIds.length,
    },
  };
}

function commitIntegrity(projection, qamCases, selectedCommit) {
  const conceptCommits = projection.graph.nodes.map((node) => node.commitSha);
  const edgeCommits = projection.graph.edges.map((edge) => edge.commitSha);
  const provenanceCommits = qamCases.flatMap((result) =>
    result.provenance.flatMap((entry) => [entry.concept_commit_sha, entry.snapshot_commit_sha]),
  );
  const readCommits = qamCases.flatMap((result) =>
    result.commit_pinned_reads.map((entry) => entry.commit_sha),
  );
  const observed = [
    projection.graph.source.commitSha,
    ...conceptCommits,
    ...edgeCommits,
    ...provenanceCommits,
    ...readCommits,
  ];
  const mismatches = observed.filter((commit) => commit !== selectedCommit);
  return {
    selected_commit_sha: selectedCommit,
    observed_commit_references: observed.length,
    mismatch_count: mismatches.length,
    consistent: mismatches.length === 0,
  };
}

export async function runEvaluation(options) {
  const paths = dataPaths(options.dataRoot);
  const questions = parseQuestions(await readJson(paths.questions));
  const gold = parseGold(await readJson(paths.gold), questions);
  const snapshot = gitSnapshot(paths.knowledge, options.commitSha);
  const generatedAt = options.generatedAt ?? snapshot.commit_generated_at;
  const projection = await projectBundle(paths.knowledge, {
    gitSha: snapshot.commit_sha,
    generatedAt,
    repository: options.repository ?? snapshot.repository,
    pathInRepository: snapshot.path_in_repository,
    strict: false,
  });
  const metadata = metadataForProjection(projection);
  const chunks = chunkDocuments(metadata.documents, metadata.metadataByPath, {
    maxCharacters: 1_000,
    overlapCharacters: 160,
  });
  const graph = new MemoryGraphAdapter(projection.graph);
  const content = new LocalMarkdownContentAdapter(paths.knowledge, snapshot.commit_sha);
  const knowledgeService = new KnowledgeService({ graph, content });
  const goldByQuestion = new Map(gold.cases.map((goldCase) => [goldCase.question_id, goldCase]));
  const statusByUid = new Map(
    [...metadata.metadataByUid].map(([uid, concept]) => [uid, concept.status]),
  );

  const caseResults = [];
  const rawQamResults = [];
  for (const question of questions.questions) {
    const goldCase = goldByQuestion.get(question.id);
    if (goldCase === undefined) throw new Error(`Missing gold case for '${question.id}'`);
    const requestedTypes = requestedTypesFor(question);
    const baseline = await runBaseline(question, chunks, requestedTypes);
    const qam = await runQam(question, graph, knowledgeService, metadata, requestedTypes);
    rawQamResults.push(qam);
    const baselineMetrics = metricFor(
      baseline.candidate_uids,
      goldCase,
      statusByUid,
      baseline.supported_paths,
    );
    const qamMetrics = metricFor(
      qam.candidate_uids,
      goldCase,
      statusByUid,
      qam.supported_paths,
    );
    const acceptanceChecks = {
      focus_resolution: qam.focus_resolution.matched,
      traversal_complete: !qam.traversal.truncated,
      required_recall: qamMetrics.recall === 1,
      excluded_scope: qamMetrics.excluded_hits.length === 0,
      lifecycle_status: qamMetrics.status_passed,
      path_coverage: qamMetrics.path_recall === 1,
      minimum_precision: qamMetrics.precision >= MINIMUM_QAM_PRECISION,
    };
    const qamAcceptance = Object.values(acceptanceChecks).every(Boolean);
    const acceptance = {
      passed: qamAcceptance,
      minimum_precision: MINIMUM_QAM_PRECISION,
      checks: acceptanceChecks,
    };
    caseResults.push({
      question,
      gold: goldCase,
      arms: {
        baseline: { ...baseline, metrics: baselineMetrics },
        qam: { ...qam, metrics: qamMetrics, acceptance },
      },
      comparison: {
        recall_delta_qam_minus_baseline: round(qamMetrics.recall - baselineMetrics.recall),
        precision_delta_qam_minus_baseline: round(qamMetrics.precision - baselineMetrics.precision),
        path_recall_delta_qam_minus_baseline: null,
        qam_acceptance_passed: qamAcceptance,
      },
    });
  }

  const commit = commitIntegrity(projection, rawQamResults, snapshot.commit_sha);
  const expectedCommit =
    gold.expected_commit_sha === null ||
    gold.expected_commit_sha === "CURRENT" ||
    gold.expected_commit_sha === "WORKTREE"
      ? snapshot.commit_sha
      : gold.expected_commit_sha;
  const expectedCommitMatched = expectedCommit === snapshot.commit_sha;
  const versions = {
    questions_schema: QUESTIONS_SCHEMA_VERSION,
    gold_schema: GOLD_SCHEMA_VERSION,
    result_schema: RESULTS_SCHEMA_VERSION,
    dataset_version: questions.dataset_version ?? gold.dataset_version,
    dataset_versions_match:
      questions.dataset_version === null ||
      gold.dataset_version === null ||
      questions.dataset_version === gold.dataset_version,
    okf_version: projection.graph.okfVersion,
    graph_schema_version: projection.graph.schemaVersion,
  };
  const sourceSnapshot = {
    repository: projection.graph.source.repository,
    commit_sha: snapshot.commit_sha,
    projection_id: projection.graph.source.projectionId,
    projection_generated_at: projection.graph.source.generatedAt,
    path_in_repository: snapshot.path_in_repository,
    knowledge_tracked: snapshot.tracked,
    knowledge_clean_at_commit: snapshot.clean_at_commit,
    untracked_knowledge_file_count: snapshot.untracked_files.length,
    expected_commit_sha: expectedCommit,
    expected_commit_matched: expectedCommitMatched,
  };
  const qamAcceptancePassed =
    caseResults.every((result) => result.arms.qam.acceptance.passed) &&
    commit.consistent &&
    expectedCommitMatched;
  const qamAcceptancePassCount = caseResults.filter(
    (result) => result.arms.qam.acceptance.passed,
  ).length;
  const baselineRecall = caseResults.map((result) => result.arms.baseline.metrics.recall);
  const qamRecall = caseResults.map((result) => result.arms.qam.metrics.recall);
  const baselinePrecision = caseResults.map((result) => result.arms.baseline.metrics.precision);
  const qamPrecision = caseResults.map((result) => result.arms.qam.metrics.precision);
  const qamPathRecall = caseResults.map((result) => result.arms.qam.metrics.path_recall);

  const result = {
    schema_version: RESULTS_SCHEMA_VERSION,
    experiment: {
      id: "industrial-component-obsolescence",
      evaluation_scope: "deterministic retrieval-and-evidence evaluation",
      llm_answer_grading: false,
      generated_at: generatedAt,
    },
    versions,
    source_snapshot: sourceSnapshot,
    corpus: {
      documents: projection.manifest.counts.documents,
      concepts: projection.manifest.counts.concepts,
      graph_nodes: projection.manifest.counts.nodes,
      graph_edges: projection.manifest.counts.edges,
      bm25_chunks: chunks.length,
      validation_errors: projection.validation.summary.errors,
      validation_warnings: projection.validation.summary.warnings,
    },
    integrity: {
      commit,
      clean_commit_required: options.requireCleanCommit === true,
      clean_commit_requirement_passed:
        options.requireCleanCommit !== true || snapshot.clean_at_commit,
    },
    cases: caseResults,
    summary: {
      question_count: caseResults.length,
      baseline: {
        mean_recall: average(baselineRecall),
        mean_precision: average(baselinePrecision),
        mean_path_recall: null,
        excluded_hit_count: caseResults.reduce(
          (sum, item) => sum + item.arms.baseline.metrics.excluded_hits.length,
          0,
        ),
      },
      qam: {
        mean_recall: average(qamRecall),
        mean_precision: average(qamPrecision),
        mean_path_recall: average(qamPathRecall),
        excluded_hit_count: caseResults.reduce(
          (sum, item) => sum + item.arms.qam.metrics.excluded_hits.length,
          0,
        ),
      },
      deltas_qam_minus_baseline: {
        mean_recall: round(average(qamRecall) - average(baselineRecall)),
        mean_precision: round(average(qamPrecision) - average(baselinePrecision)),
        mean_path_recall: null,
      },
      qam_acceptance_passed: qamAcceptancePassed,
      qam_acceptance_pass_count: qamAcceptancePassCount,
      qam_acceptance_case_count: caseResults.length,
      qam_advantage_observed:
        average(qamRecall) > average(baselineRecall) ||
        average(qamPrecision) > average(baselinePrecision) ||
        caseResults.some(
          (item) =>
            item.arms.baseline.metrics.excluded_hits.length >
            item.arms.qam.metrics.excluded_hits.length,
        ),
    },
    limitations: [
      "This run grades deterministic retrieval and evidence, not generated natural-language answers.",
      "A single synthetic corpus does not establish statistical significance or universal superiority.",
      "Both arms use the same query-derived terms, status/type scope, and concept-level top-k budget.",
      "BM25 does not emit relationship paths; its path coverage is reported as not applicable.",
      "A hybrid or GraphRAG baseline with entity resolution and traversal may reduce the observed gap.",
    ],
  };

  if (options.outputDirectory !== undefined) {
    await writeProjection(projection, join(options.outputDirectory, "qam-artifacts"));
    await atomicWriteJson(join(options.outputDirectory, "run-results.json"), result);
  }
  return result;
}
