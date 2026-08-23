"""Live Foundry smoke test that verifies actual QAM MCP call evidence."""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .contracts import (
    ALLOWED_TOOLS,
    RESPONSES_API_VERSION,
    SMOKE_REQUIRED_TOOLS,
    build_application_openai_base_url,
    canonical_tool_name,
    validate_commit_sha,
    validate_smoke_text,
)
from .http import safe_diagnostic


class SmokeAssertionError(RuntimeError):
    """The response did not prove the required QAM behavior."""


@dataclass(frozen=True)
class McpCall:
    name: str
    arguments: dict[str, Any]
    output: dict[str, Any]


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Call the published Foundry QAM Agent Application and prove its "
            "resolve/traverse/provenance/read chain."
        )
    )
    parser.add_argument("--project-endpoint", default=os.getenv("FOUNDRY_PROJECT_ENDPOINT"))
    parser.add_argument(
        "--application-name",
        default=os.getenv("QAM_FOUNDRY_APPLICATION_NAME", "qam-knowledge-application"),
    )
    parser.add_argument(
        "--registration",
        type=Path,
        default=os.getenv("QAM_FOUNDRY_ATTACHED_REGISTRATION"),
        help="Attached-phase JSON that binds this smoke to the intended published application",
    )
    parser.add_argument("--expected-commit", default=os.getenv("QAM_EXPECTED_COMMIT_SHA"))
    parser.add_argument("--concept-term", default=os.getenv("QAM_SMOKE_CONCEPT", "Wiki MCP Gateway"))
    parser.add_argument("--expected-content", default=os.getenv("QAM_SMOKE_CONTENT", "commit-pinned"))
    return parser


def build_smoke_prompt(concept_term: str, expected_commit: str, expected_content: str) -> str:
    term = validate_smoke_text(concept_term, "concept term", 200)
    marker = validate_smoke_text(expected_content, "expected content", 200)
    commit = validate_commit_sha(expected_commit)
    return f"""Run the QAM acceptance proof for the concept term {term!r}.

Make exactly these four non-parallel MCP calls in this order, using response_format=json:
1. resolve_concepts for that term.
2. get_neighbors for the first resolved concept ID.
3. trace_provenance for the same concept ID.
4. read_concepts for only that concept ID, explicitly passing commit_sha={commit}.

After the tool calls, state whether the source contains the literal marker {marker!r}. Do not call
another tool. Do not infer missing values and do not replace the full commit SHA with a branch.
"""


def execute_smoke(
    responses: Any,
    *,
    application_name: str,
    expected_commit: str,
    concept_term: str,
    expected_content: str,
) -> dict[str, object]:
    prompt = build_smoke_prompt(concept_term, expected_commit, expected_content)
    response = responses.create(
        input=prompt,
        max_tool_calls=len(SMOKE_REQUIRED_TOOLS),
        max_output_tokens=2_000,
        parallel_tool_calls=False,
        store=False,
    )
    payload = _object_dict(response)
    calls = validate_response(
        payload,
        expected_commit=expected_commit,
        expected_content=expected_content,
        concept_term=concept_term,
    )
    return {
        "status": "passed",
        "applicationName": application_name,
        "toolEvents": [f"qam.{call.name}" for call in calls],
        "verifiedCommit": expected_commit,
        "contentMarkerVerified": True,
        "responseId": str(payload.get("id", "unknown")),
    }


def validate_response(
    payload: dict[str, Any],
    *,
    expected_commit: str,
    expected_content: str,
    concept_term: str,
) -> list[McpCall]:
    commit = validate_commit_sha(expected_commit)
    marker = validate_smoke_text(expected_content, "expected content", 200)
    term = validate_smoke_text(concept_term, "concept term", 200)
    status = payload.get("status")
    if status not in {None, "completed"}:
        raise SmokeAssertionError(f"Foundry response did not complete (status={status!r})")
    output = payload.get("output")
    if not isinstance(output, list):
        raise SmokeAssertionError("Foundry response has no output event list")

    calls: list[McpCall] = []
    for raw_item in output:
        item = _object_dict(raw_item)
        item_type = item.get("type")
        if item_type == "mcp_approval_request":
            raise SmokeAssertionError("read-only QAM tool unexpectedly requested approval")
        if item_type != "mcp_call":
            continue
        server_label = item.get("server_label")
        if server_label != "qam":
            raise SmokeAssertionError("an MCP call used a server other than qam")
        raw_name = item.get("name")
        if not isinstance(raw_name, str):
            raise SmokeAssertionError("an MCP call has no tool name")
        name = canonical_tool_name(raw_name)
        if name is None or name not in ALLOWED_TOOLS:
            raise SmokeAssertionError(f"non-allowlisted MCP tool was called: {safe_diagnostic(raw_name)}")
        error_value = item.get("error")
        if error_value is not None and error_value != "":
            raise SmokeAssertionError(f"qam.{name} returned an MCP error")
        if item.get("status") not in {None, "completed"}:
            raise SmokeAssertionError(f"qam.{name} did not complete")
        arguments = _json_object(item.get("arguments"), f"qam.{name} arguments")
        raw_output = item.get("output")
        if raw_output is None:
            raise SmokeAssertionError(f"qam.{name} returned no output")
        calls.append(
            McpCall(
                name=name,
                arguments=arguments,
                output=_tool_output_object(raw_output, f"qam.{name} output"),
            )
        )

    names = tuple(call.name for call in calls)
    if names != SMOKE_REQUIRED_TOOLS:
        raise SmokeAssertionError(f"expected MCP sequence {SMOKE_REQUIRED_TOOLS!r}, received {names!r}")

    resolve, neighbors, provenance, read = calls
    for call in calls:
        if call.arguments.get("response_format") != "json":
            raise SmokeAssertionError(f"qam.{call.name} did not request structured JSON output")
    if resolve.arguments.get("terms") != [term]:
        raise SmokeAssertionError("resolve_concepts did not receive only the expected concept term")
    concept_id = neighbors.arguments.get("concept_id")
    if not isinstance(concept_id, str) or not concept_id:
        raise SmokeAssertionError("get_neighbors did not receive a concept_id")
    matches = resolve.output.get("matches")
    first_concept = (
        matches[0].get("concept")
        if isinstance(matches, list) and matches and isinstance(matches[0], dict)
        else None
    )
    if not isinstance(first_concept, dict) or first_concept.get("id") != concept_id:
        raise SmokeAssertionError("traversal did not use the first resolved concept_id")
    if provenance.arguments.get("concept_id") != concept_id:
        raise SmokeAssertionError("trace_provenance did not use the resolved concept_id")
    concept_ids = read.arguments.get("concept_ids")
    if concept_ids != [concept_id]:
        raise SmokeAssertionError("read_concepts did not use only the resolved concept_id")
    if read.arguments.get("commit_sha") != commit:
        raise SmokeAssertionError("read_concepts did not explicitly use the expected full commit SHA")

    if resolve.output.get("commit_sha") != commit:
        raise SmokeAssertionError("resolve_concepts output does not prove the expected commit")
    root = neighbors.output.get("root")
    if not isinstance(root, dict) or root.get("id") != concept_id or root.get("commitSha") != commit:
        raise SmokeAssertionError("get_neighbors output does not prove the concept and commit")
    provenance_concept = provenance.output.get("concept")
    snapshot = provenance.output.get("snapshot")
    if (
        not isinstance(provenance_concept, dict)
        or provenance_concept.get("id") != concept_id
        or not isinstance(snapshot, dict)
        or snapshot.get("commitSha") != commit
    ):
        raise SmokeAssertionError("trace_provenance output does not prove the concept and commit")
    documents = read.output.get("documents")
    if read.output.get("commit_sha") != commit or not isinstance(documents, list) or len(documents) != 1:
        raise SmokeAssertionError("read_concepts output does not prove one document at the commit")
    document_entry = documents[0]
    if not isinstance(document_entry, dict):
        raise SmokeAssertionError("read_concepts document entry is not an object")
    read_concept = document_entry.get("concept")
    document = document_entry.get("document")
    if (
        not isinstance(read_concept, dict)
        or read_concept.get("id") != concept_id
        or not isinstance(document, dict)
        or document.get("commit_sha") != commit
    ):
        raise SmokeAssertionError("read_concepts document does not prove the concept and commit")
    content = document.get("content")
    if not isinstance(content, str) or marker not in content:
        raise SmokeAssertionError("read_concepts output does not contain the expected content marker")
    return calls


def _json_object(value: Any, label: str) -> dict[str, Any]:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as error:
            raise SmokeAssertionError(f"{label} is not valid JSON") from error
    if not isinstance(value, dict):
        raise SmokeAssertionError(f"{label} is not an object")
    return value


def _tool_output_object(value: Any, label: str) -> dict[str, Any]:
    parsed = _json_object(value, label)
    structured = parsed.get("structuredContent") or parsed.get("structured_content")
    if structured is not None:
        if not isinstance(structured, dict):
            raise SmokeAssertionError(f"{label} structured content is not an object")
        return structured
    return parsed


def _object_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    model_dump = getattr(value, "model_dump", None)
    if callable(model_dump):
        dumped = model_dump(mode="json")
        if isinstance(dumped, dict):
            return dumped
    as_dict = getattr(value, "as_dict", None)
    if callable(as_dict):
        dumped = as_dict()
        if isinstance(dumped, dict):
            return dumped
    raise SmokeAssertionError("Foundry returned an unsupported response object")


def _required(value: str | None, name: str) -> str:
    if value is None or not value.strip():
        raise ValueError(f"{name} is required")
    return value.strip()


def validate_attached_registration(
    registration: dict[str, Any], *, base_url: str, application_name: str
) -> None:
    if registration.get("phase") != "attached":
        raise ValueError("smoke registration is not an attached-phase result")
    if registration.get("applicationName") != application_name:
        raise ValueError("smoke registration application name does not match")
    if registration.get("applicationOpenAIBaseUrl") != base_url:
        raise ValueError("smoke registration endpoint does not match the Foundry project")
    if registration.get("allowedTools") != list(ALLOWED_TOOLS):
        raise ValueError("smoke registration does not contain the exact read-only tool allowlist")
    version = registration.get("agentVersion")
    if not isinstance(version, str) or not version:
        raise ValueError("smoke registration has no immutable agent version")


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        project_endpoint = _required(args.project_endpoint, "--project-endpoint")
        application_name = validate_smoke_text(args.application_name, "application name", 63)
        base_url = build_application_openai_base_url(project_endpoint, application_name)
        expected_commit = validate_commit_sha(_required(args.expected_commit, "--expected-commit"))
        if args.registration is None or not args.registration.is_file():
            raise ValueError("--registration from the attached phase is required")
        registration = json.loads(args.registration.read_text(encoding="utf-8"))
        if not isinstance(registration, dict):
            raise ValueError("smoke registration file must contain a JSON object")
        validate_attached_registration(
            registration,
            base_url=base_url,
            application_name=application_name,
        )

        from azure.identity import DefaultAzureCredential, get_bearer_token_provider
        from openai import DefaultHttpxClient, OpenAI

        with DefaultAzureCredential() as credential:
            token_provider = get_bearer_token_provider(credential, "https://ai.azure.com/.default")
            with OpenAI(
                api_key=token_provider,
                base_url=base_url,
                default_query={"api-version": RESPONSES_API_VERSION},
                timeout=90.0,
                max_retries=0,
                http_client=DefaultHttpxClient(follow_redirects=False),
            ) as openai:
                result = execute_smoke(
                    openai.responses,
                    application_name=application_name,
                    expected_commit=expected_commit,
                    concept_term=args.concept_term,
                    expected_content=args.expected_content,
                )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (SmokeAssertionError, ValueError) as error:
        print(f"qam-foundry-smoke: {error}", file=sys.stderr)
        return 4
    except Exception as error:  # Azure/OpenAI exceptions vary by package version.
        status = safe_diagnostic(getattr(error, "status_code", "unavailable"))
        request_id = safe_diagnostic(getattr(error, "request_id", "unavailable"))
        print(
            f"qam-foundry-smoke: cloud request failed; type={type(error).__name__}; "
            f"status={status}; request-id={request_id}",
            file=sys.stderr,
        )
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
