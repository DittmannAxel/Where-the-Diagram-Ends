from __future__ import annotations

import copy
import json

import pytest

from qam_foundry.contracts import ALLOWED_TOOLS
from qam_foundry.smoke import (
    SmokeAssertionError,
    execute_smoke,
    validate_attached_registration,
    validate_response,
)

COMMIT = "a" * 40
CONCEPT_ID = "urn:qam:concept:wiki-mcp-gateway"
MARKER = "commit-pinned"


def call(name: str, arguments: dict[str, object], output: dict[str, object]) -> dict[str, object]:
    return {
        "type": "mcp_call",
        "server_label": "qam",
        "name": name,
        "status": "completed",
        "arguments": json.dumps(arguments),
        "output": json.dumps(output),
        "error": None,
    }


def successful_payload() -> dict[str, object]:
    return {
        "id": "resp_test",
        "status": "completed",
        "output": [
            call(
                "resolve_concepts",
                {"terms": ["Wiki MCP Gateway"], "response_format": "json"},
                {"commit_sha": COMMIT, "matches": [{"concept": {"id": CONCEPT_ID}}]},
            ),
            call(
                "get_neighbors",
                {"concept_id": CONCEPT_ID, "response_format": "json"},
                {"root": {"id": CONCEPT_ID, "commitSha": COMMIT}, "nodes": []},
            ),
            call(
                "trace_provenance",
                {"concept_id": CONCEPT_ID, "response_format": "json"},
                {"concept": {"id": CONCEPT_ID}, "snapshot": {"commitSha": COMMIT}},
            ),
            call(
                "read_concepts",
                {"concept_ids": [CONCEPT_ID], "commit_sha": COMMIT, "response_format": "json"},
                {
                    "commit_sha": COMMIT,
                    "documents": [
                        {
                            "concept": {"id": CONCEPT_ID},
                            "document": {
                                "commit_sha": COMMIT,
                                "content": f"This is {MARKER} knowledge.",
                            },
                        }
                    ],
                },
            ),
        ],
    }


def test_validates_event_chain_commit_and_content() -> None:
    calls = validate_response(
        successful_payload(),
        expected_commit=COMMIT,
        expected_content=MARKER,
        concept_term="Wiki MCP Gateway",
    )
    assert [entry.name for entry in calls] == [
        "resolve_concepts",
        "get_neighbors",
        "trace_provenance",
        "read_concepts",
    ]


@pytest.mark.parametrize(
    "mutation",
    [
        "approval",
        "write",
        "wrong_order",
        "missing_marker",
        "wrong_id",
        "wrong_output_commit",
        "wrong_term",
    ],
)
def test_smoke_fails_closed(mutation: str) -> None:
    payload = successful_payload()
    output = payload["output"]
    assert isinstance(output, list)
    if mutation == "approval":
        output.insert(0, {"type": "mcp_approval_request"})
    elif mutation == "write":
        output.append(call("propose_wiki_update", {}, {"ok": True}))
    elif mutation == "wrong_order":
        output[1], output[2] = output[2], output[1]
    elif mutation == "missing_marker":
        output[-1]["output"] = json.dumps(
            {
                "commit_sha": COMMIT,
                "documents": [
                    {
                        "concept": {"id": CONCEPT_ID},
                        "document": {"commit_sha": COMMIT, "content": "no"},
                    }
                ],
            }
        )
    elif mutation == "wrong_id":
        arguments = json.loads(output[2]["arguments"])
        arguments["concept_id"] = "urn:qam:concept:different"
        output[2]["arguments"] = json.dumps(arguments)
    elif mutation == "wrong_output_commit":
        resolve_output = json.loads(output[0]["output"])
        resolve_output["commit_sha"] = "b" * 40
        output[0]["output"] = json.dumps(resolve_output)
    else:
        resolve_arguments = json.loads(output[0]["arguments"])
        resolve_arguments["terms"] = ["different"]
        output[0]["arguments"] = json.dumps(resolve_arguments)
    with pytest.raises(SmokeAssertionError):
        validate_response(
            payload,
            expected_commit=COMMIT,
            expected_content=MARKER,
            concept_term="Wiki MCP Gateway",
        )


class Responses:
    def __init__(self):
        self.kwargs = None

    def create(self, **kwargs):
        self.kwargs = kwargs
        return copy.deepcopy(successful_payload())


def test_execute_bounds_calls_and_emits_only_evidence_summary() -> None:
    responses = Responses()
    summary = execute_smoke(
        responses,
        application_name="qam-knowledge-application",
        expected_commit=COMMIT,
        concept_term="Wiki MCP Gateway",
        expected_content=MARKER,
    )
    assert responses.kwargs["max_tool_calls"] == 4
    assert responses.kwargs["parallel_tool_calls"] is False
    assert responses.kwargs["store"] is False
    assert "extra_body" not in responses.kwargs
    assert summary["applicationName"] == "qam-knowledge-application"
    assert summary["toolEvents"] == [
        "qam.resolve_concepts",
        "qam.get_neighbors",
        "qam.trace_provenance",
        "qam.read_concepts",
    ]
    assert summary["contentMarkerVerified"] is True
    assert MARKER not in json.dumps(summary)
    assert "documents" not in json.dumps(summary)


def test_smoke_registration_binds_attached_application_and_allowlist() -> None:
    base_url = (
        "https://example.services.ai.azure.com/api/projects/qam/"
        "applications/qam-knowledge-application/protocols/openai"
    )
    registration = {
        "phase": "attached",
        "applicationName": "qam-knowledge-application",
        "applicationOpenAIBaseUrl": base_url,
        "agentVersion": "2",
        "allowedTools": list(ALLOWED_TOOLS),
    }
    validate_attached_registration(
        registration,
        base_url=base_url,
        application_name="qam-knowledge-application",
    )
    registration["allowedTools"] = ["resolve_concepts"]
    with pytest.raises(ValueError, match="allowlist"):
        validate_attached_registration(
            registration,
            base_url=base_url,
            application_name="qam-knowledge-application",
        )
