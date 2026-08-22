from __future__ import annotations

import pytest

from qam_foundry.contracts import (
    ALLOWED_TOOLS,
    ConfigurationError,
    FoundryConfig,
    build_agent_definition,
    build_application_body,
    build_application_openai_base_url,
    build_connection_body,
    build_deployment_body,
    build_identity_definition,
    canonical_tool_name,
)


def valid_config(**changes: str) -> FoundryConfig:
    values = {
        "project_endpoint": "https://example.services.ai.azure.com/api/projects/qam",
        "project_resource_id": (
            "/subscriptions/123e4567-e89b-42d3-a456-426614174000/"
            "resourceGroups/qam-rg/providers/Microsoft.CognitiveServices/accounts/example/projects/qam"
        ),
        "model": "gpt-5-mini",
        "agent_name": "qam-knowledge-agent",
        "application_name": "qam-knowledge-application",
        "deployment_name": "qam-managed-deployment",
        "connection_name": "qam-mcp-agent-identity",
        "mcp_url": "https://qam.green.azurecontainerapps.io/mcp",
        "mcp_audience": "api://123e4567-e89b-42d3-a456-426614174000",
        "allowed_mcp_host": "qam.green.azurecontainerapps.io",
    }
    values.update(changes)
    return FoundryConfig(**values)


def test_connection_and_agent_are_explicitly_read_only() -> None:
    config = valid_config().validated()
    connection = build_connection_body(config)
    properties = connection["properties"]
    assert properties["authType"] == "AgenticIdentityToken"
    assert properties["category"] == "RemoteTool"
    assert properties["audience"] == config.mcp_audience
    assert properties["credentials"] == {}

    definition = build_agent_definition(config).as_dict()
    assert definition["tools"][0]["allowed_tools"] == list(ALLOWED_TOOLS)
    assert definition["tools"][0]["require_approval"] == "never"
    assert "propose_wiki_update" not in definition["tools"][0]["allowed_tools"]
    assert build_identity_definition(config).as_dict()["tools"] == []

    application = build_application_body(config)
    assert application["properties"]["agents"] == [{"agentName": config.agent_name}]
    assert application["properties"]["authorizationPolicy"] == {"type": "Default"}
    deployment = build_deployment_body(config, "7")
    assert deployment["properties"]["deploymentType"] == "Managed"
    assert deployment["properties"]["protocols"] == [{"protocol": "Responses", "version": "1.0"}]
    assert deployment["properties"]["agents"] == [{"agentName": config.agent_name, "agentVersion": "7"}]
    assert "api-version=2026-05-01" in config.application_url
    assert "api-version=2026-05-01" in config.deployment_url
    assert config.application_responses_url.endswith(
        "/applications/qam-knowledge-application/protocols/openai/responses?api-version=2025-11-15-preview"
    )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("project_endpoint", "https://evil.example/api/projects/qam"),
        ("project_endpoint", "https://example.services.ai.azure.com/api/projects/qam?token=x"),
        ("project_endpoint", "https://example.services.ai.azure.com/api/projects/qam%3Fevil"),
        (
            "project_resource_id",
            "/subscriptions/------------------------------------/resourceGroups/qam-rg/providers/"
            "Microsoft.CognitiveServices/accounts/example/projects/qam",
        ),
        (
            "project_resource_id",
            "/subscriptions/123e4567-e89b-42d3-a456-426614174000/resourceGroups/qam%3Fevil/"
            "providers/Microsoft.CognitiveServices/accounts/example/projects/qam",
        ),
        ("mcp_url", "http://qam.green.azurecontainerapps.io/mcp"),
        ("mcp_url", "https://evil.example/mcp"),
        ("mcp_url", "https://qam.green.azurecontainerapps.io/mcp?token=x"),
        ("mcp_audience", "https://qam.green.azurecontainerapps.io"),
        ("allowed_mcp_host", "localhost"),
        ("application_name", "../../other"),
    ],
)
def test_config_rejects_token_exfiltration_shapes(field: str, value: str) -> None:
    with pytest.raises(ConfigurationError):
        valid_config(**{field: value}).validated()


def test_canonical_tool_name_requires_allowlisted_suffix() -> None:
    assert canonical_tool_name("resolve_concepts") == "resolve_concepts"
    assert canonical_tool_name("qam___trace_provenance") == "trace_provenance"
    assert canonical_tool_name("qam.read_concepts") == "read_concepts"
    assert canonical_tool_name("propose_wiki_update") is None
    assert canonical_tool_name("evil.shell") is None


@pytest.mark.parametrize(
    "resource_id",
    [
        (
            "/subscriptions/123e4567-e89b-42d3-a456-426614174000/resourceGroups/qam-rg/"
            "providers/Microsoft.CognitiveServices/accounts/other-ai/projects/qam"
        ),
        (
            "/subscriptions/123e4567-e89b-42d3-a456-426614174000/resourceGroups/qam-rg/"
            "providers/Microsoft.CognitiveServices/accounts/example/projects/other-project"
        ),
    ],
)
def test_endpoint_and_resource_id_must_identify_the_same_project(resource_id: str) -> None:
    with pytest.raises(ConfigurationError, match="different Foundry"):
        valid_config(project_resource_id=resource_id).validated()


def test_endpoint_resource_binding_is_case_insensitive() -> None:
    resource_id = (
        "/subscriptions/123e4567-e89b-42d3-a456-426614174000/resourceGroups/qam-rg/"
        "providers/Microsoft.CognitiveServices/accounts/EXAMPLE/projects/QAM"
    )
    assert valid_config(project_resource_id=resource_id).validated()


def test_application_endpoint_builder_rejects_non_project_or_encoded_paths() -> None:
    assert build_application_openai_base_url(
        "https://example.services.ai.azure.com/api/projects/qam", "qam-app"
    ).endswith("/api/projects/qam/applications/qam-app/protocols/openai")
    with pytest.raises(ConfigurationError):
        build_application_openai_base_url(
            "https://example.services.ai.azure.com/api/projects/qam%2Fother", "qam-app"
        )
