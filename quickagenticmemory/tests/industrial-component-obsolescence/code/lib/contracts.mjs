export const QUESTIONS_SCHEMA_VERSION = "qam-industrial-questions/1.0";
export const GOLD_SCHEMA_VERSION = "qam-industrial-gold/1.0";
export const RESULTS_SCHEMA_VERSION = "qam-industrial-evaluation/1.0";
export const REPORT_SCHEMA_VERSION = "qam-industrial-report/1.0";

const STATUSES = new Set(["draft", "stable", "deprecated"]);

function fail(path, message) {
  throw new TypeError(`${path}: ${message}`);
}

function record(value, path) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    fail(path, "must be an object");
  }
  return value;
}

function nonEmptyString(value, path) {
  if (typeof value !== "string" || value.trim().length === 0) {
    fail(path, "must be a non-empty string");
  }
  return value.trim();
}

function uniqueStrings(value, path, { minimum = 0, maximum = Number.MAX_SAFE_INTEGER } = {}) {
  if (!Array.isArray(value) || value.length < minimum || value.length > maximum) {
    fail(path, `must be an array with ${minimum} through ${maximum} item(s)`);
  }
  const strings = value.map((item, index) => nonEmptyString(item, `${path}[${index}]`));
  if (new Set(strings).size !== strings.length) fail(path, "must not contain duplicates");
  return strings;
}

function integer(value, path, minimum, maximum) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    fail(path, `must be an integer from ${minimum} through ${maximum}`);
  }
  return value;
}

export function parseQuestions(value) {
  const root = record(value, "questions");
  if (root.schema_version !== QUESTIONS_SCHEMA_VERSION) {
    fail("questions.schema_version", `must equal '${QUESTIONS_SCHEMA_VERSION}'`);
  }
  if (!Array.isArray(root.questions) || root.questions.length === 0) {
    fail("questions.questions", "must be a non-empty array");
  }

  const ids = new Set();
  const questions = root.questions.map((item, index) => {
    const path = `questions.questions[${index}]`;
    const question = record(item, path);
    const id = nonEmptyString(question.id, `${path}.id`);
    if (ids.has(id)) fail(`${path}.id`, `duplicate question id '${id}'`);
    ids.add(id);
    const query = nonEmptyString(question.query, `${path}.query`);
    const terms = uniqueStrings(question.terms, `${path}.terms`, { minimum: 1, maximum: 20 });
    terms.forEach((term, termIndex) => {
      if (term.length < 2 || term.length > 200) {
        fail(`${path}.terms[${termIndex}]`, "must contain 2 through 200 characters");
      }
    });
    const focusConceptUid = nonEmptyString(
      question.focus_concept_uid,
      `${path}.focus_concept_uid`,
    );
    const allowedStatuses =
      question.allowed_statuses === undefined
        ? ["stable"]
        : uniqueStrings(question.allowed_statuses, `${path}.allowed_statuses`, { minimum: 1, maximum: 3 });
    for (const [statusIndex, status] of allowedStatuses.entries()) {
      if (!STATUSES.has(status)) {
        fail(`${path}.allowed_statuses[${statusIndex}]`, "must be draft, stable, or deprecated");
      }
    }
    return {
      id,
      query,
      terms,
      focus_concept_uid: focusConceptUid,
      allowed_statuses: allowedStatuses,
      top_k: integer(question.top_k ?? 12, `${path}.top_k`, 1, 100),
      max_hops: integer(question.max_hops ?? 2, `${path}.max_hops`, 1, 2),
    };
  });

  return {
    schema_version: QUESTIONS_SCHEMA_VERSION,
    dataset_version: nonEmptyString(root.dataset_version, "questions.dataset_version"),
    questions,
  };
}

export function parseGold(value, questionsDocument) {
  const root = record(value, "gold");
  if (root.schema_version !== GOLD_SCHEMA_VERSION) {
    fail("gold.schema_version", `must equal '${GOLD_SCHEMA_VERSION}'`);
  }
  if (!Array.isArray(root.cases) || root.cases.length === 0) {
    fail("gold.cases", "must be a non-empty array");
  }

  const questions = new Map(questionsDocument.questions.map((question) => [question.id, question]));
  const caseIds = new Set();
  const cases = root.cases.map((item, index) => {
    const path = `gold.cases[${index}]`;
    const goldCase = record(item, path);
    const questionId = nonEmptyString(goldCase.question_id, `${path}.question_id`);
    const question = questions.get(questionId);
    if (question === undefined) fail(`${path}.question_id`, `does not match a question: '${questionId}'`);
    if (caseIds.has(questionId)) fail(`${path}.question_id`, `duplicate case for '${questionId}'`);
    caseIds.add(questionId);

    const required = uniqueStrings(
      goldCase.required_concept_uids,
      `${path}.required_concept_uids`,
      { minimum: 1 },
    );
    const excluded = uniqueStrings(
      goldCase.excluded_concept_uids ?? [],
      `${path}.excluded_concept_uids`,
      { minimum: 1 },
    );
    if (required.includes(question.focus_concept_uid)) {
      fail(`${path}.required_concept_uids`, "must not contain the focus concept UID");
    }
    for (const uid of required) {
      if (excluded.includes(uid)) fail(path, `UID '${uid}' cannot be both required and excluded`);
    }

    const rawStatuses = record(goldCase.required_statuses ?? {}, `${path}.required_statuses`);
    const requiredStatuses = {};
    for (const [uid, value] of Object.entries(rawStatuses)) {
      nonEmptyString(uid, `${path}.required_statuses key`);
      const status = nonEmptyString(value, `${path}.required_statuses.${uid}`);
      if (!STATUSES.has(status)) {
        fail(`${path}.required_statuses.${uid}`, "must be draft, stable, or deprecated");
      }
      requiredStatuses[uid] = status;
    }
    for (const uid of required) {
      if (requiredStatuses[uid] === undefined) {
        fail(`${path}.required_statuses`, `must declare the expected status for required UID '${uid}'`);
      }
    }
    for (const uid of Object.keys(requiredStatuses)) {
      if (!required.includes(uid)) {
        fail(`${path}.required_statuses`, `contains non-required UID '${uid}'`);
      }
    }

    const rawPaths = goldCase.required_paths ?? [];
    if (!Array.isArray(rawPaths)) fail(`${path}.required_paths`, "must be an array");
    const requiredPaths = rawPaths.map((rawPath, pathIndex) => {
      const uidPath = uniqueStrings(rawPath, `${path}.required_paths[${pathIndex}]`, { minimum: 2 });
      if (uidPath.length > 3) {
        fail(`${path}.required_paths[${pathIndex}]`, "must contain at most two hops (three UIDs)");
      }
      if (uidPath[0] !== question.focus_concept_uid) {
        fail(
          `${path}.required_paths[${pathIndex}][0]`,
          `must equal focus UID '${question.focus_concept_uid}'`,
        );
      }
      if (!required.includes(uidPath.at(-1))) {
        fail(`${path}.required_paths[${pathIndex}]`, "must end at a required concept UID");
      }
      return uidPath;
    });
    for (const uid of required) {
      if (!requiredPaths.some((uidPath) => uidPath.at(-1) === uid)) {
        fail(`${path}.required_paths`, `must contain a path ending at required UID '${uid}'`);
      }
    }

    return {
      question_id: questionId,
      required_concept_uids: required,
      excluded_concept_uids: excluded,
      required_statuses: requiredStatuses,
      required_paths: requiredPaths,
    };
  });

  if (caseIds.size !== questions.size) {
    const missing = [...questions.keys()].filter((id) => !caseIds.has(id));
    fail("gold.cases", `missing case(s) for: ${missing.join(", ")}`);
  }

  const datasetVersion = nonEmptyString(root.dataset_version, "gold.dataset_version");
  if (questionsDocument.dataset_version !== datasetVersion) {
    fail("gold.dataset_version", "must match questions.dataset_version");
  }

  let expectedCommitSha = null;
  if (root.expected_commit_sha !== undefined) {
    expectedCommitSha = nonEmptyString(root.expected_commit_sha, "gold.expected_commit_sha");
    if (expectedCommitSha !== "CURRENT" && expectedCommitSha !== "WORKTREE") {
      if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/u.test(expectedCommitSha)) {
        fail(
          "gold.expected_commit_sha",
          "must be CURRENT, WORKTREE, or a lowercase full 40/64-character Git SHA",
        );
      }
    }
  }

  return {
    schema_version: GOLD_SCHEMA_VERSION,
    dataset_version: datasetVersion,
    expected_commit_sha: expectedCommitSha,
    cases,
  };
}
