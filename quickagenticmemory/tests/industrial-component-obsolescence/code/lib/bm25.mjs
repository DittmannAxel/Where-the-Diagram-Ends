const TOKEN_PATTERN = /[\p{L}\p{N}]+(?:[-_.:/][\p{L}\p{N}]+)*/gu;

function compareText(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

export function tokenize(text) {
  return (text.normalize("NFKC").toLocaleLowerCase("en-US").match(TOKEN_PATTERN) ?? []).filter(
    (token) => token.length > 1,
  );
}

function markdownBlocks(body) {
  const normalized = body.replaceAll("\r\n", "\n").trim();
  if (normalized.length === 0) return [""];
  return normalized
    .split(/\n(?=#{1,6}\s)|\n{2,}/u)
    .map((block) => block.trim())
    .filter(Boolean);
}

function tail(text, characters) {
  if (text.length <= characters) return text;
  const candidate = text.slice(-characters);
  const firstSpace = candidate.search(/\s/u);
  return firstSpace < 0 ? candidate : candidate.slice(firstSpace + 1);
}

/**
 * Deterministic, character-bounded Markdown section chunking. Metadata is attached
 * to each chunk, matching a common local RAG indexing setup.
 */
export function chunkDocuments(documents, metadataByPath, options = {}) {
  const maxCharacters = options.maxCharacters ?? 1_000;
  const overlapCharacters = options.overlapCharacters ?? 160;
  if (maxCharacters < 300 || overlapCharacters < 0 || overlapCharacters >= maxCharacters) {
    throw new RangeError("Invalid chunk size/overlap configuration");
  }

  const chunks = [];
  for (const document of [...documents].sort((left, right) => compareText(left.path, right.path))) {
    if (document.kind !== "concept") continue;
    const metadata = metadataByPath.get(document.path);
    if (metadata === undefined) continue;
    const prefix = [
      metadata.title,
      metadata.type,
      metadata.path,
      ...metadata.aliases,
      ...metadata.tags,
      `status:${metadata.status}`,
    ].join("\n");
    const blocks = markdownBlocks(document.body);
    let buffer = "";
    let ordinal = 0;

    const emit = () => {
      const content = buffer.trim();
      if (content.length === 0) return;
      const text = `${prefix}\n\n${content}`;
      chunks.push({
        id: `${metadata.uid}#${String(ordinal).padStart(3, "0")}`,
        ordinal,
        uid: metadata.uid,
        path: metadata.path,
        title: metadata.title,
        type: metadata.type,
        status: metadata.status,
        text,
        characters: text.length,
      });
      ordinal += 1;
    };

    for (const block of blocks) {
      if (buffer.length === 0) {
        buffer = block;
        continue;
      }
      if (buffer.length + 2 + block.length <= maxCharacters) {
        buffer += `\n\n${block}`;
        continue;
      }
      emit();
      const overlap = tail(buffer, overlapCharacters);
      buffer = overlap.length === 0 ? block : `${overlap}\n\n${block}`;
      while (buffer.length > maxCharacters) {
        const current = buffer.slice(0, maxCharacters);
        buffer = `${tail(current, overlapCharacters)}${buffer.slice(maxCharacters)}`;
        const previous = buffer;
        buffer = current;
        emit();
        buffer = previous;
      }
    }
    emit();
  }
  return chunks;
}

export function bm25Search(chunks, query, options = {}) {
  const topK = options.topK ?? 12;
  const allowedStatuses = new Set(options.allowedStatuses ?? ["stable"]);
  const allowedTypes =
    options.allowedTypes === undefined ? null : new Set(options.allowedTypes);
  const k1 = options.k1 ?? 1.2;
  const b = options.b ?? 0.75;
  const candidates = chunks.filter(
    (chunk) =>
      allowedStatuses.has(chunk.status) &&
      (allowedTypes === null || allowedTypes.has(chunk.type)),
  );
  const queryTokens = tokenize(query);
  if (queryTokens.length === 0 || candidates.length === 0) return [];

  const tokenized = candidates.map((chunk) => {
    const tokens = tokenize(chunk.text);
    const frequencies = new Map();
    for (const token of tokens) frequencies.set(token, (frequencies.get(token) ?? 0) + 1);
    return { chunk, length: tokens.length, frequencies };
  });
  const averageLength =
    tokenized.reduce((total, document) => total + document.length, 0) / tokenized.length || 1;
  const queryFrequencies = new Map();
  for (const token of queryTokens) {
    queryFrequencies.set(token, (queryFrequencies.get(token) ?? 0) + 1);
  }

  const documentFrequency = new Map();
  for (const token of queryFrequencies.keys()) {
    documentFrequency.set(
      token,
      tokenized.reduce((count, document) => count + Number(document.frequencies.has(token)), 0),
    );
  }

  return tokenized
    .map((document) => {
      let score = 0;
      const matchedTokens = [];
      for (const [token, queryFrequency] of queryFrequencies) {
        const frequency = document.frequencies.get(token) ?? 0;
        if (frequency === 0) continue;
        matchedTokens.push(token);
        const df = documentFrequency.get(token) ?? 0;
        const idf = Math.log(1 + (tokenized.length - df + 0.5) / (df + 0.5));
        const normalization = frequency + k1 * (1 - b + b * (document.length / averageLength));
        const queryWeight = 1 + Math.log(queryFrequency);
        score += idf * ((frequency * (k1 + 1)) / normalization) * queryWeight;
      }
      return {
        ...document.chunk,
        score: Number(score.toFixed(8)),
        matched_tokens: matchedTokens.sort(compareText),
      };
    })
    .filter((result) => result.score > 0)
    .sort(
      (left, right) =>
        right.score - left.score || compareText(left.path, right.path) || left.ordinal - right.ordinal,
    )
    .slice(0, topK);
}
