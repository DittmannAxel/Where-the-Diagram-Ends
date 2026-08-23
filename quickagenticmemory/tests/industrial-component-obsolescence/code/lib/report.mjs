import { REPORT_SCHEMA_VERSION } from "./contracts.mjs";

function percent(value) {
  return `${Math.round(Number(value ?? 0) * 100)}%`;
}

function percentagePointDelta(value) {
  const points = Math.round(Number(value ?? 0) * 100);
  if (points === 0) return "±0 pp";
  return `${points > 0 ? "+" : ""}${points} pp`;
}

function decimal(value) {
  const number = Number(value ?? 0);
  return Number.isFinite(number) ? number.toFixed(3) : "0.000";
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function shortSha(value) {
  const sha = String(value ?? "");
  return sha.length > 12 ? sha.slice(0, 12) : sha;
}

function shortUid(value) {
  const uid = String(value ?? "unresolved");
  const segment = uid.split(":").at(-1) ?? uid;
  return segment
    .split("-")
    .map((token) => (/^(?:iol|pkg|pal|fat|sat|fb|cr|sb|io|m8|m8s|v\d+)$/iu.test(token) ? token.toUpperCase() : token))
    .join("-");
}

function uidKind(value) {
  const uid = String(value ?? "");
  const rules = [
    [":machine-variant:", "Delivered variant"],
    [":component:", "Component"],
    [":io-map:", "I/O mapping"],
    [":plc:", "PLC diagnostic"],
    [":parameter-set:", "Parameter set"],
    [":test:", "FAT / SAT evidence"],
    [":service-bulletin:", "Service bulletin"],
    [":change-request:", "Controlled change"],
  ];
  return rules.find(([needle]) => uid.includes(needle))?.[1] ?? "Knowledge concept";
}

function badge(passed, passText = "PASS", failText = "REVIEW", extraClass = "") {
  return `<span class="status-mark ${passed ? "is-pass" : "is-review"} ${extraClass}">${escapeHtml(passed ? passText : failText)}</span>`;
}

function uidTags(values, emptyText = "None") {
  const items = values ?? [];
  if (items.length === 0) return `<span class="empty-note">${escapeHtml(emptyText)}</span>`;
  return `<ul class="uid-tags">${items
    .map((uid) => `<li><code title="${escapeHtml(uid)}">${escapeHtml(shortUid(uid))}</code></li>`)
    .join("")}</ul>`;
}

function conceptTitleMap(item) {
  const entries = [
    ...(item.baseline.ranked_chunks ?? []),
    ...(item.baseline.ranked_concepts ?? []),
    ...(item.qam.ranked_concepts ?? []),
    ...(item.qam.direct_backlinks ?? []),
  ];
  return new Map(entries.filter((entry) => entry?.uid).map((entry) => [entry.uid, entry.title]));
}

function renderImpactChain(item, commitSha, snapshotVerified) {
  const paths = (item.qam.paths ?? []).filter((path) => path.found);
  if (paths.length === 0) {
    return '<p class="empty-state">No bounded graph path was returned for this case.</p>';
  }

  const titles = conceptTitleMap(item);
  return `<div class="chain-register" role="list" aria-label="${snapshotVerified ? "Commit-pinned" : "Run-labeled"} bidirectional LINKS_TO paths">${paths
    .map((path, index) => {
      const sequence = path.uid_sequence ?? [];
      const accessiblePath = sequence
        .map((uid) => titles.get(uid) ?? shortUid(uid))
        .join(" linked bidirectionally with ");
      const nodes = sequence
        .map((uid, nodeIndex) => {
          const title = titles.get(uid) ?? shortUid(uid);
          return `${nodeIndex === 0 ? "" : '<span class="rail-coupling" aria-hidden="true"><i>↔</i></span>'}
            <span class="rail-node" role="listitem">
              <span class="rail-node-kind">${escapeHtml(uidKind(uid))}</span>
              <strong>${escapeHtml(title)}</strong>
              <code title="${escapeHtml(uid)}">${escapeHtml(shortUid(uid))}</code>
            </span>`;
        })
        .join("");
      return `<div class="chain-row" role="listitem">
        <div class="chain-row-label">
          <span>PATH ${String(index + 1).padStart(2, "0")}</span>
          <b>${escapeHtml(path.hop_count ?? Math.max(0, sequence.length - 1))} hop${Number(path.hop_count ?? sequence.length - 1) === 1 ? "" : "s"}</b>
        </div>
        <div class="rail-viewport" tabindex="0" aria-label="${escapeHtml(accessiblePath)}">
          <div class="rail">
            <span class="commit-pin ${snapshotVerified ? "" : "is-unverified"}" title="${escapeHtml(snapshotVerified ? `Pinned source commit ${commitSha}` : "Run commit label only; the knowledge tree is not tracked and clean at this commit")}">
              <span>${snapshotVerified ? "PINNED COMMIT" : "RUN COMMIT LABEL"}</span>
              <code>${escapeHtml(shortSha(commitSha))}</code>
            </span>
            <span class="rail-coupling rail-coupling-pin" aria-hidden="true"><i></i></span>
            ${nodes}
          </div>
        </div>
      </div>`;
    })
    .join("")}</div>`;
}

function renderChunkList(item) {
  const chunks = item.baseline.ranked_chunks ?? [];
  if (chunks.length === 0) {
    return '<p class="empty-state">No lexical chunk matched this case.</p>';
  }

  return `<ol class="chunk-list">${chunks
    .map(
      (chunk, index) => `<li>
        <span class="chunk-rank">${String(index + 1).padStart(2, "0")}</span>
        <span class="chunk-copy">
          <strong>${escapeHtml(chunk.title ?? shortUid(chunk.uid))}</strong>
          <code>${escapeHtml(chunk.path ?? chunk.id)}</code>
          <span class="chunk-terms">${(chunk.matched_tokens ?? [])
            .map((token) => `<em>${escapeHtml(token)}</em>`)
            .join("")}</span>
        </span>
        <span class="chunk-score"><small>BM25</small>${escapeHtml(decimal(chunk.score))}</span>
      </li>`,
    )
    .join("")}</ol>`;
}

function renderMetricMatrix(item) {
  const excludedDelta =
    (item.qam.metrics.excluded_hits ?? []).length -
    (item.baseline.metrics.excluded_hits ?? []).length;
  const rows = [
    {
      label: "Required concept recall",
      note: `${item.qam.metrics.required_count} gold concepts`,
      baseline: percent(item.baseline.metrics.recall),
      qam: percent(item.qam.metrics.recall),
      delta: percentagePointDelta(item.comparison.recall_delta_qam_minus_baseline),
      good: item.comparison.recall_delta_qam_minus_baseline > 0,
    },
    {
      label: "Relationship-path recall",
      note: "BM25 arm emits no paths",
      baseline: "N/A",
      qam: percent(item.qam.metrics.path_recall),
      delta: "not comparable",
      good: false,
    },
    {
      label: "Retrieval precision",
      note: "Different retrieval units",
      baseline: percent(item.baseline.metrics.precision),
      qam: percent(item.qam.metrics.precision),
      delta: percentagePointDelta(item.comparison.precision_delta_qam_minus_baseline),
      good: item.comparison.precision_delta_qam_minus_baseline > 0,
    },
    {
      label: "Excluded-scope hits",
      note: "Lower is better",
      baseline: String((item.baseline.metrics.excluded_hits ?? []).length),
      qam: String((item.qam.metrics.excluded_hits ?? []).length),
      delta: excludedDelta === 0 ? "±0" : `${excludedDelta > 0 ? "+" : ""}${excludedDelta}`,
      good: excludedDelta < 0,
    },
  ];

  return `<div class="metric-table-wrap"><table class="metric-table">
    <thead><tr><th scope="col">Control measure</th><th scope="col">A · BM25 chunks</th><th scope="col">B · QAM graph</th><th scope="col">B − A</th></tr></thead>
    <tbody>${rows
      .map(
        (row) => `<tr>
          <th scope="row">${escapeHtml(row.label)}<small>${escapeHtml(row.note)}</small></th>
          <td>${escapeHtml(row.baseline)}</td>
          <td>${escapeHtml(row.qam)}</td>
          <td class="metric-delta ${row.good ? "is-positive" : ""}">${escapeHtml(row.delta)}</td>
        </tr>`,
      )
      .join("")}</tbody>
  </table></div>`;
}

function renderEvidenceLedger(item, commitSha, snapshotVerified) {
  const provenanceByUid = new Map(
    (item.qam.provenance ?? []).map((entry) => [entry.uid, entry]),
  );
  const rows = (item.qam.commit_pinned_reads ?? []).map((read) => ({
    ...read,
    provenance: provenanceByUid.get(read.uid),
  }));
  if (rows.length === 0) {
    return '<p class="empty-state">No commit-pinned content reads were recorded.</p>';
  }
  return `<div class="evidence-table-wrap"><table class="evidence-table">
    <thead><tr><th scope="col">Evidence concept</th><th scope="col">Source</th><th scope="col">Content hash</th><th scope="col">Commit pin</th></tr></thead>
    <tbody>${rows
      .map((row) => {
        const sourceCount = row.provenance?.source_count ?? 0;
        const commitMatched = row.commit_sha === commitSha;
        return `<tr>
          <th scope="row"><span>${escapeHtml(shortUid(row.uid))}</span><code title="${escapeHtml(row.uid)}">${escapeHtml(row.path)}</code></th>
          <td>${sourceCount} resource${sourceCount === 1 ? "" : "s"}</td>
          <td><code>${escapeHtml(shortSha(row.content_hash))}</code></td>
          <td>${badge(commitMatched && snapshotVerified, shortSha(row.commit_sha), commitMatched ? "UNVERIFIED" : "MISMATCH")}</td>
        </tr>`;
      })
      .join("")}</tbody>
  </table></div>`;
}

function renderAcceptanceChecks(item) {
  const acceptance = item.qam.acceptance ?? { minimum_precision: 0, checks: {} };
  const machineChecks = acceptance.checks ?? {};
  const checks = [
    [machineChecks.focus_resolution === true, "Focus resolution", item.qam.focus_resolution.resolved_uid],
    [machineChecks.traversal_complete === true, "Traversal complete", `≤ ${item.qam.traversal.max_hops} hops`],
    [machineChecks.required_recall === true, "Required recall", percent(item.qam.metrics.recall)],
    [machineChecks.excluded_scope === true, "Excluded scope", `${(item.qam.metrics.excluded_hits ?? []).length} hits`],
    [machineChecks.lifecycle_status === true, "Lifecycle status", "controlled status"],
    [machineChecks.path_coverage === true, "Link-path coverage", percent(item.qam.metrics.path_recall)],
    [machineChecks.minimum_precision === true, "Minimum precision", `${percent(item.qam.metrics.precision)} ≥ ${percent(acceptance.minimum_precision)}`],
  ];
  return `<ul class="acceptance-checks">${checks
    .map(
      ([passed, label, value]) => `<li class="${passed ? "is-pass" : "is-review"}">
        <span aria-hidden="true">${passed ? "✓" : "!"}</span>
        <b>${escapeHtml(label)}</b>
        <code>${escapeHtml(value)}</code>
      </li>`,
    )
    .join("")}</ul>`;
}

function renderCasePanel(item, index, report, snapshotVerified) {
  const panelId = `case-panel-${index + 1}`;
  const tabId = `case-tab-${index + 1}`;
  const baselineMissed = item.baseline.metrics.missed_required_uids ?? [];
  const qamMissed = item.qam.metrics.missed_required_uids ?? [];
  return `<article class="case-panel" id="${panelId}" role="tabpanel" aria-labelledby="${tabId}" data-case-panel${index === 0 ? "" : " hidden"}>
    <header class="case-header">
      <div class="case-identity">
        <span class="case-sequence">CASE ${String(index + 1).padStart(2, "0")} / ${String(report.cases.length).padStart(2, "0")}</span>
        <p>${escapeHtml(item.id)}</p>
      </div>
      <div class="case-question">
        <p class="section-kicker">Engineering question</p>
        <h2>${escapeHtml(item.query)}</h2>
        <p class="resolution-terms"><b>Resolution terms</b>${item.terms.map((term) => `<code>${escapeHtml(term)}</code>`).join("")}</p>
      </div>
      ${badge(item.qam.acceptance?.passed === true, "ACCEPTANCE PASS", "ACCEPTANCE REVIEW", "case-result")}
    </header>

    <section class="case-section" aria-labelledby="measure-${index + 1}">
      <div class="section-heading">
        <span>01</span><div><p>Comparative controls</p><h3 id="measure-${index + 1}">What each retrieval arm recovered</h3></div>
      </div>
      ${renderMetricMatrix(item)}
      <div class="scope-ledger">
        <div><p>Gold required</p>${uidTags(item.required_uids)}</div>
        <div><p>BM25 missed</p>${uidTags(baselineMissed, "None missed")}</div>
        <div><p>QAM missed</p>${uidTags(qamMissed, "None missed")}</div>
      </div>
    </section>

    <section class="case-section evidence-comparison" aria-labelledby="impact-${index + 1}">
      <div class="section-heading section-heading-wide">
        <span>02</span><div><p>Signature evidence view</p><h3 id="impact-${index + 1}">A bounded link-path rail beside disconnected top-k chunks</h3></div>
      </div>
      <div class="evidence-grid">
        <div class="graph-arm">
          <header class="arm-header">
            <div><span>ARM B</span><h4>Quick Agentic Memory</h4></div>
            <p>Resolve · traverse LINKS_TO ↔ · read at commit</p>
          </header>
          <div class="focus-lock">
            <span>Resolved focus</span>
            <code>${escapeHtml(item.qam.focus_resolution.resolved_uid ?? "unresolved")}</code>
            ${badge(item.qam.focus_resolution.matched, "EXACT", "MISMATCH")}
          </div>
          ${renderImpactChain(item, report.source_snapshot.commit_sha, snapshotVerified)}
        </div>
        <aside class="baseline-arm">
          <header class="arm-header">
            <div><span>ARM A</span><h4>Classical local BM25</h4></div>
            <p>Ranked lexical chunks; no relation order</p>
          </header>
          ${renderChunkList(item)}
        </aside>
      </div>
    </section>

    <section class="case-section" aria-labelledby="integrity-${index + 1}">
      <div class="section-heading">
        <span>03</span><div><p>Traceability ledger</p><h3 id="integrity-${index + 1}">Every QAM evidence read names its source commit</h3></div>
      </div>
      <div class="integrity-grid">
        <div>${renderEvidenceLedger(item, report.source_snapshot.commit_sha, snapshotVerified)}</div>
        <aside>
          <p class="minor-heading">Acceptance checks</p>
          ${renderAcceptanceChecks(item)}
          <dl class="method-calls">
            <div><dt>Resolve</dt><dd>${escapeHtml(item.qam.method_calls.resolve_concepts)}</dd></div>
            <div><dt>Neighbors</dt><dd>${escapeHtml(item.qam.method_calls.get_neighbors)}</dd></div>
            <div><dt>Paths</dt><dd>${escapeHtml(item.qam.method_calls.find_path)}</dd></div>
            <div><dt>Pinned reads</dt><dd>${escapeHtml(item.qam.method_calls.read_concepts)}</dd></div>
          </dl>
        </aside>
      </div>
    </section>
  </article>`;
}

function renderCaseRegister(report) {
  const questionLabel = `${report.cases.length} question${report.cases.length === 1 ? "" : "s"}.`;
  return `<aside class="case-register screen-only" aria-label="Evaluation case register">
    <header>
      <p>Controlled test register</p>
      <h2>${escapeHtml(questionLabel)}<br>One source snapshot.</h2>
      <span id="active-case-label" aria-live="polite">Case 1 of ${report.cases.length}</span>
    </header>
    <div class="case-tabs" role="tablist" aria-orientation="vertical">${report.cases
      .map((item, index) => {
        const recallDelta = item.comparison.recall_delta_qam_minus_baseline;
        return `<button type="button" role="tab" id="case-tab-${index + 1}" aria-controls="case-panel-${index + 1}" aria-selected="${index === 0 ? "true" : "false"}" tabindex="${index === 0 ? "0" : "-1"}" data-case-tab="${index + 1}">
          <span class="tab-number">${String(index + 1).padStart(2, "0")}</span>
          <span class="tab-copy"><b>${escapeHtml(item.id)}</b><small>${escapeHtml(item.query)}</small></span>
          <span class="tab-delta ${recallDelta > 0 ? "is-positive" : ""}">${escapeHtml(percentagePointDelta(recallDelta))}<small>recall</small></span>
        </button>`;
      })
      .join("")}</div>
    <p class="keyboard-hint">Use ↑ ↓ to change case</p>
  </aside>`;
}

export function buildReportData(result) {
  return {
    schema_version: REPORT_SCHEMA_VERSION,
    title: "BM25 lexical retrieval vs bounded QAM link traversal",
    subtitle: "Deterministic retrieval and evidence evaluation — no LLM answer grading",
    generated_at: result.experiment.generated_at,
    source_snapshot: result.source_snapshot,
    corpus: result.corpus,
    versions: result.versions,
    summary: result.summary,
    integrity: result.integrity,
    cases: result.cases.map((item) => ({
      id: item.question.id,
      query: item.question.query,
      terms: item.question.terms,
      required_uids: item.gold.required_concept_uids,
      excluded_uids: item.gold.excluded_concept_uids,
      required_statuses: item.gold.required_statuses,
      required_paths: item.gold.required_paths,
      baseline: {
        method: item.arms.baseline.method,
        generated_answer: item.arms.baseline.generated_answer,
        top_k_unit: item.arms.baseline.top_k_unit,
        top_k: item.arms.baseline.top_k,
        chunking: item.arms.baseline.chunking,
        metrics: item.arms.baseline.metrics,
        ranked_chunks: item.arms.baseline.ranked_chunks,
        ranked_concepts: item.arms.baseline.ranked_concepts,
      },
      qam: {
        method: item.arms.qam.method,
        generated_answer: item.arms.qam.generated_answer,
        top_k_unit: item.arms.qam.top_k_unit,
        top_k: item.arms.qam.top_k,
        metrics: item.arms.qam.metrics,
        focus_resolution: item.arms.qam.focus_resolution,
        ranked_concepts: item.arms.qam.ranked_concepts,
        paths: item.arms.qam.paths,
        direct_backlinks: item.arms.qam.direct_backlinks,
        traversal: item.arms.qam.traversal,
        provenance: item.arms.qam.provenance,
        commit_pinned_reads: item.arms.qam.commit_pinned_reads,
        method_calls: item.arms.qam.method_calls,
        acceptance: item.arms.qam.acceptance,
      },
      comparison: item.comparison,
    })),
    limitations: result.limitations,
  };
}

export function renderStaticHtml(report) {
  const snapshotVerified =
    report.integrity.commit.consistent &&
    report.source_snapshot.expected_commit_matched &&
    report.source_snapshot.knowledge_tracked &&
    report.source_snapshot.knowledge_clean_at_commit;
  const acceptedCases = report.cases.filter((item) => item.qam.acceptance?.passed === true).length;
  const primaryDelta = report.summary.deltas_qam_minus_baseline.mean_recall;
  const casePanels = report.cases
    .map((item, index) => renderCasePanel(item, index, report, snapshotVerified))
    .join("");
  const cleanDescription = !report.source_snapshot.knowledge_tracked
    ? "Knowledge tree is not tracked at this commit"
    : report.source_snapshot.knowledge_clean_at_commit
      ? "Tracked knowledge matches the selected commit"
      : "Tracked knowledge differs from the selected commit";
  const snapshotLabel = snapshotVerified
    ? "Verified immutable source snapshot"
    : "Selected source state · not immutable";

  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'">
  <title>${escapeHtml(report.title)}</title>
  <style>
    :root { color-scheme:light; --paper:#f4f6f5; --surface:#fff; --steel:#34434b; --steel-2:#607079; --graphite:#182126; --line:#b8c2c6; --line-soft:#d9dfe1; --oxide:#b44a2d; --oxide-pale:#f4e4df; --safety:#f2c84b; --safety-pale:#fff8dc; --signal:#2f6690; --signal-pale:#e4eef5; --pass:#236347; --pass-pale:#e2efe8; --font-display:"Arial Narrow","Aptos Narrow","Roboto Condensed","Helvetica Neue Condensed",Arial,sans-serif; --font-body:"Segoe UI","Helvetica Neue",Arial,sans-serif; --font-mono:"SFMono-Regular",Consolas,"Liberation Mono",monospace; }
    * { box-sizing:border-box; }
    html { scroll-behavior:smooth; }
    body { margin:0; color:var(--graphite); background-color:var(--paper); background-image:linear-gradient(rgba(52,67,75,.035) 1px,transparent 1px),linear-gradient(90deg,rgba(52,67,75,.035) 1px,transparent 1px); background-size:32px 32px; font:15px/1.55 var(--font-body); }
    button,code { font:inherit; } code { font-family:var(--font-mono); overflow-wrap:anywhere; } button { color:inherit; } a,button { -webkit-tap-highlight-color:transparent; }
    :focus-visible { outline:3px solid var(--safety); outline-offset:3px; } [hidden] { display:none !important; }
    h1,h2,h3,h4,p,dl,dd { margin-top:0; } h1,h2,h3,h4 { font-family:var(--font-display); font-stretch:condensed; color:var(--graphite); }
    .report-shell { width:min(1480px,calc(100% - 48px)); margin:0 auto; padding:28px 0 72px; }
    .masthead { border-top:8px solid var(--steel); background:var(--surface); border-bottom:1px solid var(--steel); }
    .document-line { display:grid; grid-template-columns:minmax(220px,1fr) auto auto; align-items:center; min-height:42px; border-bottom:1px solid var(--line); color:var(--steel); font:700 11px/1.2 var(--font-display); letter-spacing:.12em; text-transform:uppercase; }
    .document-line span { padding:0 18px; } .document-line span+span { border-left:1px solid var(--line); }
    .hero { display:grid; grid-template-columns:minmax(0,1.4fr) minmax(280px,.6fr); gap:48px; padding:clamp(34px,6vw,78px) clamp(22px,5vw,72px) 44px; }
    .hero-kicker,.section-kicker,.minor-heading { color:var(--oxide); font:800 11px/1.2 var(--font-display); letter-spacing:.16em; text-transform:uppercase; }
    .hero h1 { max-width:880px; margin-bottom:22px; font-size:clamp(42px,6vw,82px); line-height:.93; letter-spacing:-.035em; text-transform:uppercase; }
    .hero h1 span { color:var(--signal); } .hero-copy { max-width:720px; margin:0; color:var(--steel); font-size:clamp(17px,2vw,21px); line-height:1.45; }
    .finding-stamp { align-self:end; border:2px solid var(--steel); background:var(--paper); }
    .finding-stamp>span { display:block; padding:8px 12px; background:var(--steel); color:white; font:800 11px/1 var(--font-display); letter-spacing:.14em; text-transform:uppercase; }
    .finding-stamp strong { display:block; padding:18px 16px 5px; font:800 clamp(34px,5vw,58px)/1 var(--font-display); letter-spacing:-.03em; }
    .finding-stamp p { margin:0; padding:0 16px 18px; color:var(--steel-2); }
    .delta-banner { display:grid; grid-template-columns:minmax(260px,.8fr) 2fr; border-top:1px solid var(--steel); }
    .primary-delta { padding:26px clamp(22px,4vw,48px); color:white; background:var(--signal); }
    .primary-delta span { display:block; font:800 11px/1.2 var(--font-display); letter-spacing:.13em; text-transform:uppercase; }
    .primary-delta strong { display:block; margin-top:7px; font:800 clamp(42px,6vw,70px)/1 var(--font-display); letter-spacing:-.03em; }
    .delta-ledger { display:grid; grid-template-columns:repeat(3,1fr); background:var(--surface); }
    .delta-ledger div { padding:25px 22px; border-left:1px solid var(--line); }
    .delta-ledger dt { color:var(--steel-2); font:800 10px/1.2 var(--font-display); letter-spacing:.12em; text-transform:uppercase; }
    .delta-ledger dd { margin:8px 0 0; font:800 29px/1 var(--font-display); }
    .snapshot-control { display:grid; grid-template-columns:1.4fr repeat(3,minmax(140px,.6fr)); border:1px solid var(--steel); border-top:0; background:var(--safety-pale); }
    .snapshot-control>div { min-width:0; padding:16px 18px; } .snapshot-control>div+div { border-left:1px solid var(--line); }
    .snapshot-control p { margin-bottom:5px; color:var(--steel-2); font:800 10px/1.2 var(--font-display); letter-spacing:.12em; text-transform:uppercase; }
    .snapshot-control code { display:block; font-size:12px; } .snapshot-control .snapshot-main code { color:var(--graphite); font-size:14px; font-weight:700; }
    .workbench { display:grid; grid-template-columns:300px minmax(0,1fr); gap:22px; margin-top:28px; align-items:start; }
    .case-register { position:sticky; top:18px; border:1px solid var(--steel); background:var(--surface); }
    .case-register>header { padding:19px 18px 16px; border-bottom:1px solid var(--steel); }
    .case-register>header p { margin-bottom:6px; color:var(--oxide); font:800 10px/1 var(--font-display); letter-spacing:.14em; text-transform:uppercase; }
    .case-register h2 { margin-bottom:13px; font-size:23px; line-height:1.05; text-transform:uppercase; }
    .case-register>header span { color:var(--steel-2); font:700 11px/1 var(--font-mono); }
    .case-tabs { display:grid; }
    .case-tabs button { width:100%; min-height:73px; display:grid; grid-template-columns:30px minmax(0,1fr) 48px; gap:9px; align-items:center; padding:10px 10px 10px 13px; border:0; border-bottom:1px solid var(--line-soft); border-left:5px solid transparent; background:transparent; text-align:left; cursor:pointer; }
    .case-tabs button:hover { background:var(--paper); } .case-tabs button[aria-selected="true"] { border-left-color:var(--oxide); background:var(--signal-pale); }
    .tab-number { color:var(--steel-2); font:800 16px/1 var(--font-display); } .tab-copy { min-width:0; }
    .tab-copy b { display:block; margin-bottom:3px; font:800 11px/1.2 var(--font-mono); }
    .tab-copy small { display:-webkit-box; overflow:hidden; color:var(--steel-2); font-size:11px; line-height:1.25; -webkit-box-orient:vertical; -webkit-line-clamp:2; }
    .tab-delta { text-align:right; font:800 11px/1 var(--font-mono); } .tab-delta.is-positive { color:var(--pass); }
    .tab-delta small { display:block; margin-top:4px; color:var(--steel-2); font:800 8px/1 var(--font-display); letter-spacing:.08em; text-transform:uppercase; }
    .keyboard-hint { margin:0; padding:11px 16px; color:var(--steel-2); background:var(--paper); font:700 10px/1.2 var(--font-mono); }
    .case-panel { min-width:0; border:1px solid var(--steel); background:var(--surface); }
    .case-header { display:grid; grid-template-columns:126px minmax(0,1fr) auto; gap:23px; align-items:start; padding:25px; border-bottom:5px solid var(--steel); }
    .case-identity { padding-right:18px; border-right:1px solid var(--line); } .case-sequence { color:var(--oxide); font:800 11px/1 var(--font-display); letter-spacing:.13em; }
    .case-identity p { margin:12px 0 0; font:700 12px/1.35 var(--font-mono); }
    .case-question h2 { max-width:900px; margin:6px 0 13px; font-size:clamp(24px,3vw,36px); line-height:1.07; }
    .resolution-terms { display:flex; flex-wrap:wrap; align-items:center; gap:6px; margin:0; }
    .resolution-terms b { margin-right:4px; color:var(--steel-2); font:800 10px/1 var(--font-display); letter-spacing:.1em; text-transform:uppercase; }
    .resolution-terms code { padding:4px 6px; border:1px solid var(--line); background:var(--paper); font-size:10px; }
    .status-mark { display:inline-block; white-space:nowrap; padding:6px 8px; border:1px solid currentColor; font:900 10px/1 var(--font-display); letter-spacing:.1em; text-transform:uppercase; }
    .status-mark.is-pass { color:var(--pass); background:var(--pass-pale); } .status-mark.is-review { color:var(--oxide); background:var(--oxide-pale); }
    .case-result { margin-top:2px; padding:8px 10px; }
    .case-section { padding:28px 25px 30px; border-bottom:1px solid var(--steel); } .case-section:last-child { border-bottom:0; }
    .section-heading { display:grid; grid-template-columns:42px minmax(0,1fr); gap:13px; align-items:start; margin-bottom:20px; }
    .section-heading>span { display:grid; width:38px; height:38px; place-items:center; color:white; background:var(--steel); font:800 15px/1 var(--font-display); }
    .section-heading p { margin-bottom:3px; color:var(--steel-2); font:800 10px/1 var(--font-display); letter-spacing:.13em; text-transform:uppercase; }
    .section-heading h3 { margin:0; font-size:24px; line-height:1.08; }
    .metric-table-wrap,.evidence-table-wrap { overflow-x:auto; } table { width:100%; border-collapse:collapse; }
    .metric-table { min-width:650px; border-top:2px solid var(--steel); }
    .metric-table th,.metric-table td { padding:12px 14px; border-bottom:1px solid var(--line); border-right:1px solid var(--line-soft); text-align:right; }
    .metric-table th:last-child,.metric-table td:last-child { border-right:0; }
    .metric-table thead th { color:var(--steel-2); background:var(--paper); font:800 10px/1.2 var(--font-display); letter-spacing:.1em; text-transform:uppercase; }
    .metric-table thead th:first-child,.metric-table tbody th { text-align:left; }
    .metric-table tbody th { width:40%; font-size:13px; } .metric-table tbody th small { display:block; margin-top:2px; color:var(--steel-2); font-weight:400; }
    .metric-table td { font:800 19px/1 var(--font-mono); } .metric-delta { background:var(--paper); } .metric-delta.is-positive { color:var(--pass); background:var(--pass-pale); }
    .scope-ledger { display:grid; grid-template-columns:1.25fr 1fr 1fr; border:1px solid var(--line); border-top:0; }
    .scope-ledger>div { min-width:0; padding:13px; } .scope-ledger>div+div { border-left:1px solid var(--line); }
    .scope-ledger p,.minor-heading { margin-bottom:8px; } .scope-ledger p { color:var(--steel-2); font:800 10px/1 var(--font-display); letter-spacing:.1em; text-transform:uppercase; }
    .uid-tags { display:flex; flex-wrap:wrap; gap:5px; padding:0; margin:0; list-style:none; } .uid-tags code { display:block; padding:3px 5px; background:var(--paper); border:1px solid var(--line-soft); font-size:9px; }
    .empty-note,.empty-state { color:var(--steel-2); font-style:italic; }
    .evidence-comparison { padding-left:0; padding-right:0; } .section-heading-wide { padding:0 25px; }
    .evidence-grid { display:grid; grid-template-columns:minmax(0,1.45fr) minmax(320px,.55fr); border-top:1px solid var(--steel); }
    .graph-arm,.baseline-arm { min-width:0; } .baseline-arm { border-left:1px solid var(--steel); background:#fafbfb; }
    .arm-header { min-height:88px; display:flex; align-items:flex-start; justify-content:space-between; gap:16px; padding:18px 20px; border-bottom:1px solid var(--line); }
    .arm-header span { color:var(--oxide); font:800 10px/1 var(--font-display); letter-spacing:.13em; } .arm-header h4 { margin:4px 0 0; font-size:22px; text-transform:uppercase; }
    .arm-header p { max-width:210px; margin:0; color:var(--steel-2); font-size:11px; text-align:right; }
    .focus-lock { display:grid; grid-template-columns:auto minmax(0,1fr) auto; gap:10px; align-items:center; padding:11px 20px; border-bottom:1px solid var(--line); background:var(--signal-pale); }
    .focus-lock>span { color:var(--signal); font:800 10px/1 var(--font-display); letter-spacing:.1em; text-transform:uppercase; } .focus-lock code { font-size:10px; }
    .chain-register { padding:9px 0 18px; } .chain-row { display:grid; grid-template-columns:72px minmax(0,1fr); min-width:0; border-bottom:1px solid var(--line-soft); } .chain-row:last-child { border-bottom:0; }
    .chain-row-label { padding:16px 8px 12px 14px; border-right:1px solid var(--line); } .chain-row-label span,.chain-row-label b { display:block; }
    .chain-row-label span { color:var(--steel-2); font:800 9px/1 var(--font-display); letter-spacing:.08em; } .chain-row-label b { margin-top:6px; font:800 10px/1 var(--font-mono); }
    .rail-viewport { min-width:0; padding:12px 14px; overflow-x:auto; scrollbar-color:var(--signal) var(--paper); } .rail { display:flex; width:max-content; min-width:100%; align-items:stretch; }
    .commit-pin { width:102px; flex:0 0 102px; display:flex; flex-direction:column; justify-content:center; padding:8px; border:2px solid var(--steel); background:var(--safety); }
    .commit-pin.is-unverified { border-color:var(--oxide); background:var(--oxide-pale); }
    .commit-pin span { font:900 8px/1 var(--font-display); letter-spacing:.1em; } .commit-pin code { margin-top:5px; font-size:9px; font-weight:700; }
    .rail-node { width:145px; min-height:72px; flex:0 0 145px; display:flex; flex-direction:column; justify-content:center; padding:9px 10px; border:2px solid var(--signal); background:var(--surface); }
    .rail-node-kind { color:var(--signal); font:800 8px/1 var(--font-display); letter-spacing:.08em; text-transform:uppercase; } .rail-node strong { margin-top:4px; font-size:11px; line-height:1.2; } .rail-node code { margin-top:5px; color:var(--steel-2); font-size:8px; }
    .rail-coupling { position:relative; width:32px; flex:0 0 32px; display:grid; place-items:center; }
    .rail-coupling::before { content:""; position:absolute; left:0; right:0; top:50%; height:2px; transform:translateY(-50%); background:var(--signal); }
    .rail-coupling i { position:relative; z-index:1; padding:0 2px; color:var(--signal); background:var(--surface); font:normal 800 15px/1 var(--font-mono); }
    .rail-coupling-pin::before { background:var(--steel); } .rail-coupling-pin i { display:none; }
    .chunk-list { padding:0; margin:0; list-style:none; } .chunk-list li { display:grid; grid-template-columns:34px minmax(0,1fr) 48px; gap:9px; align-items:start; padding:12px 14px; border-bottom:1px solid var(--line-soft); }
    .chunk-list li:last-child { border-bottom:0; } .chunk-rank { color:var(--oxide); font:800 17px/1 var(--font-display); } .chunk-copy { min-width:0; }
    .chunk-copy strong,.chunk-copy code { display:block; } .chunk-copy strong { font-size:11px; line-height:1.2; } .chunk-copy code { margin-top:4px; color:var(--steel-2); font-size:8px; }
    .chunk-terms { display:flex; flex-wrap:wrap; gap:3px; margin-top:5px; } .chunk-terms em { padding:2px 4px; color:var(--steel); background:var(--safety-pale); font:normal 8px/1 var(--font-mono); }
    .chunk-score { color:var(--steel); font:800 10px/1 var(--font-mono); text-align:right; } .chunk-score small { display:block; margin-bottom:4px; color:var(--steel-2); font:800 8px/1 var(--font-display); letter-spacing:.08em; }
    .integrity-grid { display:grid; grid-template-columns:minmax(0,1.4fr) minmax(230px,.6fr); gap:22px; } .integrity-grid>aside { border-left:1px solid var(--line); padding-left:20px; }
    .evidence-table { min-width:620px; border-top:2px solid var(--steel); } .evidence-table th,.evidence-table td { padding:10px 11px; border-bottom:1px solid var(--line); text-align:left; font-size:11px; }
    .evidence-table thead th { color:var(--steel-2); background:var(--paper); font:800 9px/1 var(--font-display); letter-spacing:.09em; text-transform:uppercase; }
    .evidence-table tbody th span,.evidence-table tbody th code { display:block; } .evidence-table tbody th code { margin-top:3px; color:var(--steel-2); font-size:8px; font-weight:400; }
    .acceptance-checks { display:grid; gap:1px; padding:0; margin:0; background:var(--line); list-style:none; } .acceptance-checks li { display:grid; grid-template-columns:22px minmax(0,1fr); gap:0 6px; padding:9px; background:var(--surface); }
    .acceptance-checks li>span { grid-row:span 2; display:grid; width:19px; height:19px; place-items:center; color:white; background:var(--pass); font-weight:800; } .acceptance-checks li.is-review>span { background:var(--oxide); }
    .acceptance-checks b { font-size:11px; } .acceptance-checks code { color:var(--steel-2); font-size:9px; }
    .method-calls { display:grid; grid-template-columns:1fr 1fr; margin:16px 0 0; border:1px solid var(--line); } .method-calls div { padding:9px; } .method-calls div:nth-child(even) { border-left:1px solid var(--line); } .method-calls div:nth-child(n+3) { border-top:1px solid var(--line); }
    .method-calls dt { color:var(--steel-2); font:800 8px/1 var(--font-display); letter-spacing:.08em; text-transform:uppercase; } .method-calls dd { margin:4px 0 0; font:800 17px/1 var(--font-mono); }
    .methodology { margin-top:28px; border:1px solid var(--steel); background:var(--surface); } .methodology>header { display:grid; grid-template-columns:minmax(0,1fr) auto; gap:20px; padding:22px 25px; border-bottom:1px solid var(--steel); }
    .methodology h2 { margin-bottom:0; font-size:26px; text-transform:uppercase; } .honesty-mark { align-self:start; padding:8px 10px; color:var(--graphite); background:var(--safety); border:1px solid var(--steel); font:900 10px/1 var(--font-display); letter-spacing:.1em; }
    .method-grid { display:grid; grid-template-columns:1fr 1fr; } .method-grid>section { padding:22px 25px; } .method-grid>section+section { border-left:1px solid var(--line); }
    .method-grid h3 { margin-bottom:8px; font-size:20px; } .method-grid p { margin-bottom:0; color:var(--steel); } .method-grid code { font-size:11px; }
    .limitations { padding:20px 25px; border-top:1px solid var(--line); background:var(--safety-pale); } .limitations h3 { margin-bottom:10px; font-size:17px; text-transform:uppercase; } .limitations ul { margin:0; padding-left:19px; color:var(--steel); } .limitations li+li { margin-top:4px; }
    .report-footer { display:flex; justify-content:space-between; gap:24px; padding:16px 2px 0; color:var(--steel-2); font:700 10px/1.4 var(--font-mono); }
    @media (max-width:1100px) { .workbench{grid-template-columns:244px minmax(0,1fr)} .evidence-grid{grid-template-columns:1fr} .baseline-arm{border-left:0;border-top:1px solid var(--steel)} .integrity-grid{grid-template-columns:1fr} .integrity-grid>aside{border-left:0;border-top:1px solid var(--line);padding:20px 0 0} }
    @media (max-width:820px) { .report-shell{width:min(100% - 24px,1480px);padding-top:12px} .document-line{grid-template-columns:1fr auto}.document-line span:nth-child(2){display:none}.hero,.delta-banner,.snapshot-control,.workbench{grid-template-columns:1fr}.hero{gap:28px;padding:36px 22px 28px}.hero h1{font-size:clamp(41px,13vw,66px)}.finding-stamp{width:min(100%,360px)}.delta-ledger{grid-template-columns:repeat(3,1fr)}.snapshot-control>div+div{border-left:0;border-top:1px solid var(--line)}.case-register{position:static;overflow:hidden}.case-register>header h2 br{display:none}.case-tabs{grid-auto-flow:column;grid-auto-columns:minmax(230px,72vw);overflow-x:auto}.case-tabs button{border-bottom:0;border-right:1px solid var(--line-soft)}.keyboard-hint{display:none}.case-header{grid-template-columns:1fr auto}.case-identity{grid-column:1/-1;padding:0 0 10px;border-right:0;border-bottom:1px solid var(--line)}.case-question{grid-column:1/-1}.case-result{grid-column:1/-1;justify-self:start}.scope-ledger,.method-grid{grid-template-columns:1fr}.scope-ledger>div+div,.method-grid>section+section{border-left:0;border-top:1px solid var(--line)} }
    @media (max-width:560px) { .document-line{grid-template-columns:1fr}.document-line span:nth-child(3){display:none}.delta-ledger{grid-template-columns:1fr}.delta-ledger div{border-left:0;border-top:1px solid var(--line)}.case-section,.case-header{padding:21px 16px}.section-heading-wide{padding:0 16px}.arm-header{flex-direction:column}.arm-header p{max-width:none;text-align:left}.focus-lock{grid-template-columns:1fr auto}.focus-lock code{grid-column:1/-1}.methodology>header{grid-template-columns:1fr}.report-footer{flex-direction:column} }
    @media (prefers-reduced-motion:reduce) { html{scroll-behavior:auto} *,*::before,*::after{animation-duration:.01ms !important;animation-iteration-count:1 !important;transition-duration:.01ms !important} }
    @page { size:A4 landscape; margin:11mm; }
    @media print { body{background:white;color:black;font-size:10pt}.report-shell{width:100%;padding:0}.screen-only{display:none !important}.masthead,.case-panel,.methodology{border-color:#333}.hero{padding:12mm 8mm 8mm}.hero h1{font-size:36pt}.delta-banner,.snapshot-control{break-inside:avoid}.workbench{display:block;margin-top:8mm}.case-panel[hidden]{display:block !important}.case-panel{break-before:page}.case-panel:first-child{break-before:auto}.case-section{break-inside:auto}.metric-table-wrap,.evidence-table-wrap,.rail-viewport{overflow:visible}.chain-row,.metric-table,.evidence-table,.integrity-grid{break-inside:avoid}.methodology{break-before:page}.report-footer{break-inside:avoid} }
  </style>
</head>
<body>
<main class="report-shell">
  <header class="masthead">
    <div class="document-line"><span>Where the Diagram Ends / Retrieval comparison</span><span>Dataset ${escapeHtml(report.versions.dataset_version)}</span><span>${escapeHtml(report.generated_at)}</span></div>
    <div class="hero">
      <div><p class="hero-kicker">Controlled synthetic demonstration · IOL-M8 end-of-life</p><h1>BM25 lexical retrieval<br><span>vs bounded QAM link traversal.</span></h1><p class="hero-copy">When one I/O component reaches end of life, the relevant context can include delivered variants, electrical mappings, PLC diagnostics, parameters, and FAT/SAT records. This controlled synthetic demonstration compares which evidence each retrieval method returns.</p></div>
      <aside class="finding-stamp" aria-label="Evaluation finding"><span>Machine-readable acceptance</span><strong>${acceptedCases}/${report.cases.length}</strong><p>cases met every declared QAM acceptance check, including minimum precision.</p></aside>
    </div>
    <div class="delta-banner"><div class="primary-delta"><span>Required concept recall · QAM minus BM25</span><strong>${escapeHtml(percentagePointDelta(primaryDelta))}</strong></div><dl class="delta-ledger"><div><dt>Mean precision delta</dt><dd>${escapeHtml(percentagePointDelta(report.summary.deltas_qam_minus_baseline.mean_precision))}</dd></div><div><dt>Excluded hits · BM25 / QAM</dt><dd>${escapeHtml(report.summary.baseline.excluded_hit_count)} / ${escapeHtml(report.summary.qam.excluded_hit_count)}</dd></div><div><dt>QAM link-path coverage · BM25 N/A</dt><dd>${escapeHtml(percent(report.summary.qam.mean_path_recall))}</dd></div></dl></div>
  </header>

  <section class="snapshot-control" aria-label="Source snapshot integrity">
    <div class="snapshot-main"><p>${escapeHtml(snapshotLabel)}</p><code>${escapeHtml(report.source_snapshot.commit_sha)}</code></div>
    <div><p>Repository / path</p><code>${escapeHtml(report.source_snapshot.repository)}</code><code>${escapeHtml(report.source_snapshot.path_in_repository)}</code></div>
    <div><p>Commit references</p><code>${escapeHtml(report.integrity.commit.observed_commit_references)} checked / ${escapeHtml(report.integrity.commit.mismatch_count)} mismatches</code></div>
    <div><p>Integrity disposition</p>${badge(snapshotVerified, "REPRODUCIBLE", "UNVERIFIED WORKTREE")}<code>${escapeHtml(cleanDescription)}</code></div>
  </section>

  <div class="workbench">${renderCaseRegister(report)}<section class="case-stage" aria-label="Selected evaluation case">${casePanels}</section></div>

  <section class="methodology" aria-labelledby="methodology-heading">
    <header><div><p class="hero-kicker">Method statement</p><h2 id="methodology-heading">Scope of this controlled synthetic demonstration</h2></div><span class="honesty-mark">RETRIEVAL ONLY · NO LLM ANSWER GRADING</span></header>
    <div class="method-grid"><section><h3>Arm A · BM25 lexical retrieval</h3><p>Deterministic BM25 over Markdown chunks (maximum ${escapeHtml(report.cases[0]?.baseline.chunking?.max_characters ?? 1_000)} characters, ${escapeHtml(report.cases[0]?.baseline.chunking?.overlap_characters ?? 160)} overlap). It returns ranked chunks and does not generate an answer or relationship path.</p></section><section><h3>Arm B · Bounded QAM link traversal</h3><p>Alias resolution starts from the named component, then follows backlinks and neighbors over explicit <code>LINKS_TO</code> edges in both directions for at most two hops. Path records, source lineage, and content reads carry the selected Git commit; the report marks them unverified unless the knowledge tree is tracked and clean. It does not generate an answer.</p></section></div>
    <div class="limitations"><h3>Interpretation limits</h3><ul>${report.limitations.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul></div>
  </section>
  <footer class="report-footer"><span>Schema ${escapeHtml(report.schema_version)} · OKF ${escapeHtml(report.versions.okf_version)} · ${escapeHtml(report.corpus.concepts)} concepts / ${escapeHtml(report.corpus.graph_edges)} graph edges / ${escapeHtml(report.corpus.bm25_chunks)} chunks</span><span>Generated ${escapeHtml(report.generated_at)}</span></footer>
</main>
<script>
  (function () {
    "use strict";
    var tabs = Array.prototype.slice.call(document.querySelectorAll("[data-case-tab]"));
    var panels = Array.prototype.slice.call(document.querySelectorAll("[data-case-panel]"));
    var activeLabel = document.getElementById("active-case-label");
    if (tabs.length === 0 || tabs.length !== panels.length) return;
    function selectCase(index, moveFocus) {
      var safeIndex = Math.max(0, Math.min(index, tabs.length - 1));
      tabs.forEach(function (tab, itemIndex) {
        var selected = itemIndex === safeIndex;
        tab.setAttribute("aria-selected", selected ? "true" : "false");
        tab.setAttribute("tabindex", selected ? "0" : "-1");
        panels[itemIndex].hidden = !selected;
      });
      if (activeLabel) activeLabel.textContent = "Case " + (safeIndex + 1) + " of " + tabs.length;
      if (moveFocus) tabs[safeIndex].focus();
    }
    tabs.forEach(function (tab, index) {
      tab.addEventListener("click", function () { selectCase(index, false); });
      tab.addEventListener("keydown", function (event) {
        var next = index;
        if (event.key === "ArrowDown" || event.key === "ArrowRight") next = (index + 1) % tabs.length;
        else if (event.key === "ArrowUp" || event.key === "ArrowLeft") next = (index - 1 + tabs.length) % tabs.length;
        else if (event.key === "Home") next = 0;
        else if (event.key === "End") next = tabs.length - 1;
        else return;
        event.preventDefault();
        selectCase(next, true);
      });
    });
  }());
</script>
</body>
</html>\n`;
  return html.replace(/[ \t]+$/gmu, "");
}
