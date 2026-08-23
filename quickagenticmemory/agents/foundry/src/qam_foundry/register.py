"""Publish a QAM Agent Application, then attach its Entra-authenticated MCP tool."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import requests

from .contracts import (
    ALLOWED_TOOLS,
    FoundryConfig,
    build_agent_definition,
    build_application_body,
    build_connection_body,
    build_deployment_body,
    build_identity_definition,
)
from .http import AzureJsonClient, AzureRequestError, safe_diagnostic

ARM_SCOPE = "https://management.azure.com/.default"
GRAPH_SCOPE = "https://graph.microsoft.com/.default"
ACCESS_RECEIPT_VERSION = "qam-foundry-access/1.0"
_TERMINAL_FAILURES = {"Canceled", "Deleted", "Deleting", "Failed", "Stopped"}
_PROVISIONING_TIMEOUT_SECONDS = 300.0
_POLL_INTERVAL_SECONDS = 3.0
_CONTAINER_APP_RESOURCE_ID = re.compile(
    r"^/subscriptions/(?P<subscription>[0-9a-fA-F-]{36})/"
    r"resourceGroups/[A-Za-z0-9._()-]{1,90}/providers/"
    r"Microsoft\.App/containerApps/[A-Za-z0-9][A-Za-z0-9-]{0,31}$",
    re.IGNORECASE,
)
_GRAPH_OBJECT_KEY = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Publish a Microsoft Foundry Agent Application with a distinct Entra identity, then "
            "attach the read-only QAM MCP tool after an administrator grants that identity access."
        )
    )
    parser.add_argument(
        "phase",
        choices=("identity", "attach"),
        help=(
            "Publish a tool-less application identity first; attach the MCP-enabled version only "
            "after Qam.Read and EasyAuth access are configured"
        ),
    )
    parser.add_argument("--project-endpoint", default=os.getenv("FOUNDRY_PROJECT_ENDPOINT"))
    parser.add_argument("--project-resource-id", default=os.getenv("FOUNDRY_PROJECT_RESOURCE_ID"))
    parser.add_argument("--model", default=os.getenv("FOUNDRY_MODEL_DEPLOYMENT_NAME"))
    parser.add_argument("--agent-name", default=os.getenv("QAM_FOUNDRY_AGENT_NAME", "qam-knowledge-agent"))
    parser.add_argument(
        "--application-name",
        default=os.getenv("QAM_FOUNDRY_APPLICATION_NAME", "qam-knowledge-application"),
    )
    parser.add_argument(
        "--deployment-name",
        default=os.getenv("QAM_FOUNDRY_DEPLOYMENT_NAME", "qam-managed-deployment"),
    )
    parser.add_argument(
        "--connection-name", default=os.getenv("QAM_FOUNDRY_CONNECTION_NAME", "qam-mcp-agent-identity")
    )
    parser.add_argument("--mcp-url", default=os.getenv("QAM_MCP_URL"))
    parser.add_argument("--mcp-audience", default=os.getenv("QAM_MCP_AUDIENCE"))
    parser.add_argument("--allowed-mcp-host", default=os.getenv("QAM_ALLOWED_MCP_HOST"))
    parser.add_argument("--output", type=Path, help="Write the non-secret registration result as JSON")
    parser.add_argument(
        "--registration",
        type=Path,
        help="Published-identity JSON; required by attach to bind the exact authorized application",
    )
    parser.add_argument(
        "--access-receipt",
        type=Path,
        help=(
            "configure-access JSON receipt; required by live attach to re-verify Qam.Read and "
            "the exact Container Apps EasyAuth boundary"
        ),
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Validate and print planned payloads without Azure changes"
    )
    return parser


def _required(value: str | None, name: str) -> str:
    if value is None or not value.strip():
        raise ValueError(f"{name} is required")
    return value.strip()


def config_from_args(args: argparse.Namespace) -> FoundryConfig:
    return FoundryConfig(
        project_endpoint=_required(args.project_endpoint, "--project-endpoint"),
        project_resource_id=_required(args.project_resource_id, "--project-resource-id"),
        model=_required(args.model, "--model"),
        agent_name=args.agent_name,
        application_name=args.application_name,
        deployment_name=args.deployment_name,
        connection_name=args.connection_name,
        mcp_url=_required(args.mcp_url, "--mcp-url"),
        mcp_audience=_required(args.mcp_audience, "--mcp-audience"),
        allowed_mcp_host=_required(args.allowed_mcp_host, "--allowed-mcp-host"),
    ).validated()


def create_published_identity(
    config: FoundryConfig, credential: Any, arm: AzureJsonClient
) -> dict[str, object]:
    """Publish an inert version and return only the distinct Agent Application identity."""
    from azure.ai.projects import AIProjectClient

    with AIProjectClient(endpoint=config.project_endpoint, credential=credential) as project:
        created = project.agents.create_version(
            agent_name=config.agent_name,
            definition=build_identity_definition(config),
            description="QAM application awaiting its read-only downstream access grant",
            metadata={"component": "quick-agentic-memory", "access": "pending"},
        )
        agent = project.agents.get(agent_name=config.agent_name)
    version = _created_version(created, config, expected_tools=())
    agent_id = getattr(agent, "id", None)
    if not isinstance(agent_id, str):
        raise RuntimeError("Foundry did not return the created agent ID")

    arm.request(
        "PUT",
        config.application_url,
        scope=ARM_SCOPE,
        body=build_application_body(config, agent_id),
        expected_statuses=(200, 201, 202),
        allow_empty_response=True,
    )
    application = _wait_for_application(arm, config)
    identity = _application_identity(application)
    if identity is None:
        raise RuntimeError("published Agent Application has no complete defaultInstanceIdentity")

    arm.request(
        "PUT",
        config.deployment_url,
        scope=ARM_SCOPE,
        body=build_deployment_body(config, version),
        expected_statuses=(200, 201, 202),
        allow_empty_response=True,
    )
    _wait_for_deployment(arm, config, version)

    client_id, principal_id = identity
    return {
        "agentName": config.agent_name,
        "agentVersion": version,
        "projectResourceId": config.project_resource_id,
        "applicationName": config.application_name,
        "applicationResourceId": config.application_resource_id,
        "applicationOpenAIBaseUrl": config.application_openai_base_url,
        "deploymentName": config.deployment_name,
        "applicationClientId": client_id,
        "applicationPrincipalId": principal_id,
        "connectionName": config.connection_name,
        "mcpUrl": config.mcp_url,
        "mcpAudience": config.mcp_audience,
        "phase": "published-identity",
        "accessContract": {
            "identitySource": "AgentApplication.defaultInstanceIdentity",
            "allowedClientApplicationIds": [client_id],
            "allowedPrincipalIds": [principal_id],
            "requiredAppRole": "Qam.Read",
        },
    }


def attach_mcp(
    config: FoundryConfig,
    credential: Any,
    arm: AzureJsonClient,
    registration: dict[str, Any],
    access_receipt: dict[str, Any],
    mcp_session: requests.Session,
) -> dict[str, object]:
    """Verify the authorized application identity, then deploy the MCP-enabled version."""
    from azure.ai.projects import AIProjectClient

    expected = _registration_identity(registration, config)
    access = _access_receipt_contract(access_receipt, registration, config)
    _verify_attach_access_gate(config, expected, access, arm)
    _verify_mcp_boundary(config, mcp_session)

    arm.request(
        "PUT",
        config.connection_url,
        scope=ARM_SCOPE,
        body=build_connection_body(config),
        expected_statuses=(200, 201, 202),
        allow_empty_response=True,
    )
    _verify_attach_access_gate(config, expected, access, arm)
    with AIProjectClient(endpoint=config.project_endpoint, credential=credential) as project:
        created = project.agents.create_version(
            agent_name=config.agent_name,
            definition=build_agent_definition(config),
            description="Read-only, commit-pinned Quick Agentic Memory application agent",
            metadata={"component": "quick-agentic-memory", "access": "read-only"},
        )
    version = _created_version(created, config, expected_tools=ALLOWED_TOOLS)

    _verify_attach_access_gate(config, expected, access, arm)
    arm.request(
        "PUT",
        config.deployment_url,
        scope=ARM_SCOPE,
        body=build_deployment_body(config, version),
        expected_statuses=(200, 201, 202),
        allow_empty_response=True,
    )
    _wait_for_deployment(arm, config, version)
    after = _wait_for_application(arm, config, timeout_seconds=0)
    if _application_identity(after) != expected:
        raise RuntimeError("Agent Application identity changed while updating its deployment")

    client_id, principal_id = expected
    return {
        "agentName": config.agent_name,
        "agentVersion": version,
        "projectResourceId": config.project_resource_id,
        "applicationName": config.application_name,
        "applicationResourceId": config.application_resource_id,
        "applicationOpenAIBaseUrl": config.application_openai_base_url,
        "deploymentName": config.deployment_name,
        "applicationClientId": client_id,
        "applicationPrincipalId": principal_id,
        "connectionName": config.connection_name,
        "mcpUrl": config.mcp_url,
        "mcpAudience": config.mcp_audience,
        "phase": "attached",
        "allowedTools": list(ALLOWED_TOOLS),
        "accessReceiptVersion": ACCESS_RECEIPT_VERSION,
        "containerAppResourceId": access["containerAppResourceId"],
    }


def _verify_attach_access_gate(
    config: FoundryConfig,
    expected: tuple[str, str],
    access: dict[str, str],
    client: AzureJsonClient,
) -> None:
    application = _wait_for_application(client, config, timeout_seconds=0)
    if _application_identity(application) != expected:
        raise ValueError("live Agent Application identity differs from the access registration")
    _verify_live_access(config, expected, access, client)


def _access_receipt_contract(
    receipt: dict[str, Any], registration: dict[str, Any], config: FoundryConfig
) -> dict[str, str]:
    """Bind an administrator-issued access receipt to this exact attach request."""
    client_id, principal_id = _registration_identity(registration, config)
    if receipt.get("receiptVersion") != ACCESS_RECEIPT_VERSION or receipt.get("phase") != "access-configured":
        raise ValueError("access receipt has an unsupported version or phase")

    expected_text = {
        "agentName": config.agent_name,
        "applicationName": config.application_name,
        "mcpUrl": config.mcp_url,
        "mcpApiAudience": config.mcp_audience,
        "requiredAppRole": "Qam.Read",
    }
    for field, expected in expected_text.items():
        if receipt.get(field) != expected:
            raise ValueError(f"access receipt {field} does not match the requested configuration")

    for field, expected in {
        "applicationResourceId": config.application_resource_id,
        "projectResourceId": config.project_resource_id,
    }.items():
        actual = receipt.get(field)
        if not isinstance(actual, str) or actual.rstrip("/").casefold() != expected.rstrip("/").casefold():
            raise ValueError(f"access receipt {field} does not match the requested configuration")

    uuid_fields = {
        "applicationClientId": client_id,
        "applicationPrincipalId": principal_id,
    }
    normalized: dict[str, str] = {}
    for field, expected in uuid_fields.items():
        actual = _normalized_uuid(receipt.get(field))
        if actual != _normalized_uuid(expected):
            raise ValueError(f"access receipt {field} does not match the Agent Application identity")
        normalized[field] = actual

    for field in (
        "mcpApiClientId",
        "mcpApiApplicationObjectId",
        "mcpApiPrincipalId",
        "qamReadAppRoleId",
    ):
        normalized[field] = _required_receipt_uuid(receipt, field)
    normalized["qamReadAssignmentId"] = _required_graph_object_key(receipt, "qamReadAssignmentId")
    if _normalized_uuid(config.mcp_audience.removeprefix("api://")) != normalized["mcpApiClientId"]:
        raise ValueError("access receipt MCP API client ID does not match the configured audience")
    if not _uuid_list_matches(receipt.get("allowedClientApplicationIds"), [client_id]):
        raise ValueError("access receipt client allowlist does not match the Agent Application identity")
    if not _uuid_list_matches(receipt.get("allowedPrincipalIds"), [principal_id]):
        raise ValueError("access receipt principal allowlist does not match the Agent Application identity")

    container_app_resource_id = receipt.get("containerAppResourceId")
    container_match = (
        _CONTAINER_APP_RESOURCE_ID.fullmatch(container_app_resource_id)
        if isinstance(container_app_resource_id, str)
        else None
    )
    if container_match is None or _normalized_uuid(container_match.group("subscription")) is None:
        raise ValueError("access receipt has no valid Container App resource ID")
    normalized["containerAppResourceId"] = container_app_resource_id
    return normalized


def _verify_live_access(
    config: FoundryConfig,
    identity: tuple[str, str],
    access: dict[str, str],
    client: AzureJsonClient,
) -> None:
    """Re-read Graph and Container Apps state immediately before an attach mutation."""
    client_id, principal_id = identity
    api_principal_id = access["mcpApiPrincipalId"]
    api_application = client.request(
        "GET",
        (
            "https://graph.microsoft.com/v1.0/applications/"
            f"{access['mcpApiApplicationObjectId']}?$select=id,appId,appRoles"
        ),
        scope=GRAPH_SCOPE,
    )
    app_roles = api_application.get("appRoles")
    qam_roles = (
        [
            role
            for role in app_roles
            if isinstance(role, dict)
            and role.get("value") == "Qam.Read"
            and role.get("isEnabled") is True
            and isinstance(role.get("allowedMemberTypes"), list)
            and "Application" in role["allowedMemberTypes"]
        ]
        if isinstance(app_roles, list)
        else []
    )
    if (
        _normalized_uuid(api_application.get("id")) != access["mcpApiApplicationObjectId"]
        or _normalized_uuid(api_application.get("appId")) != access["mcpApiClientId"]
        or len(qam_roles) != 1
        or _normalized_uuid(qam_roles[0].get("id")) != access["qamReadAppRoleId"]
    ):
        raise ValueError("live MCP API application does not expose the receipt's exact Qam.Read role")

    api_service_principal = client.request(
        "GET",
        (
            "https://graph.microsoft.com/v1.0/servicePrincipals/"
            f"{api_principal_id}?$select=id,appId,appRoleAssignmentRequired"
        ),
        scope=GRAPH_SCOPE,
    )
    if (
        _normalized_uuid(api_service_principal.get("id")) != api_principal_id
        or _normalized_uuid(api_service_principal.get("appId")) != access["mcpApiClientId"]
        or api_service_principal.get("appRoleAssignmentRequired") is not True
    ):
        raise ValueError("live MCP API service principal does not match the access receipt")

    caller_service_principal = client.request(
        "GET",
        (f"https://graph.microsoft.com/v1.0/servicePrincipals/{principal_id}?$select=id,appId"),
        scope=GRAPH_SCOPE,
    )
    if _normalized_uuid(caller_service_principal.get("id")) != _normalized_uuid(
        principal_id
    ) or _normalized_uuid(caller_service_principal.get("appId")) != _normalized_uuid(client_id):
        raise ValueError("live Agent Application service principal does not match its published identity")

    assignment = client.request(
        "GET",
        (
            "https://graph.microsoft.com/v1.0/servicePrincipals/"
            f"{principal_id}/appRoleAssignments/{access['qamReadAssignmentId']}"
            "?$select=id,appRoleId,principalId,resourceId"
        ),
        scope=GRAPH_SCOPE,
    )
    expected_assignment = {
        "appRoleId": access["qamReadAppRoleId"],
        "principalId": _normalized_uuid(principal_id),
        "resourceId": api_principal_id,
    }
    if _normalized_graph_object_key(assignment.get("id")) != access["qamReadAssignmentId"] or any(
        _normalized_uuid(assignment.get(field)) != expected for field, expected in expected_assignment.items()
    ):
        raise ValueError("live Qam.Read app-role assignment does not match the access receipt")

    container_id = access["containerAppResourceId"]
    container_app = client.request(
        "GET",
        f"https://management.azure.com{container_id}?api-version=2025-01-01",
        scope=ARM_SCOPE,
    )
    properties = container_app.get("properties")
    configuration = properties.get("configuration") if isinstance(properties, dict) else None
    ingress = configuration.get("ingress") if isinstance(configuration, dict) else None
    fqdn = ingress.get("fqdn") if isinstance(ingress, dict) else None
    if (
        not isinstance(fqdn, str)
        or fqdn.rstrip(".").casefold() != config.allowed_mcp_host.rstrip(".").casefold()
        or ingress.get("external") is not True
    ):
        raise ValueError("live Container App ingress does not match the configured MCP host")

    auth_config = client.request(
        "GET",
        (f"https://management.azure.com{container_id}/authConfigs/current?api-version=2025-01-01"),
        scope=ARM_SCOPE,
    )
    _verify_auth_config(auth_config, config, identity, access)


def _verify_auth_config(
    auth_config: dict[str, Any],
    config: FoundryConfig,
    identity: tuple[str, str],
    access: dict[str, str],
) -> None:
    properties = auth_config.get("properties")
    if not isinstance(properties, dict):
        raise ValueError("live Container Apps authConfig returned no properties")
    platform = properties.get("platform")
    global_validation = properties.get("globalValidation")
    http_settings = properties.get("httpSettings")
    providers = properties.get("identityProviders")
    aad = providers.get("azureActiveDirectory") if isinstance(providers, dict) else None
    registration = aad.get("registration") if isinstance(aad, dict) else None
    validation = aad.get("validation") if isinstance(aad, dict) else None
    policy = validation.get("defaultAuthorizationPolicy") if isinstance(validation, dict) else None
    principals = policy.get("allowedPrincipals") if isinstance(policy, dict) else None
    client_id, principal_id = identity
    valid = (
        isinstance(platform, dict)
        and platform.get("enabled") is True
        and isinstance(global_validation, dict)
        and global_validation.get("unauthenticatedClientAction") == "Return401"
        and global_validation.get("excludedPaths") == ["/healthz"]
        and isinstance(http_settings, dict)
        and http_settings.get("requireHttps") is True
        and isinstance(aad, dict)
        and aad.get("enabled") is True
        and isinstance(registration, dict)
        and _normalized_uuid(registration.get("clientId")) == access["mcpApiClientId"]
        and isinstance(validation, dict)
        and validation.get("allowedAudiences") == [config.mcp_audience]
        and isinstance(policy, dict)
        and _uuid_list_matches(policy.get("allowedApplications"), [client_id])
        and isinstance(principals, dict)
        and principals.get("groups") == []
        and _uuid_list_matches(principals.get("identities"), [principal_id])
    )
    if not valid:
        raise ValueError(
            "live Container Apps authConfig does not exactly enforce the MCP audience, client, and principal"
        )


def _verify_mcp_boundary(config: FoundryConfig, session: requests.Session) -> None:
    """Verify public health and anonymous denial without sending any credential."""
    parts = urlsplit(config.mcp_url)
    health_url = urlunsplit((parts.scheme, parts.netloc, "/healthz", "", ""))
    checks = ((health_url, 200, "health"), (config.mcp_url, 401, "anonymous MCP"))
    for url, expected_status, label in checks:
        try:
            response = session.request(
                "GET",
                url,
                headers={"Accept": "application/json"},
                timeout=15.0,
                allow_redirects=False,
            )
        except requests.RequestException as error:
            raise RuntimeError(f"QAM {label} preflight request failed") from error
        try:
            if response.status_code != expected_status:
                raise RuntimeError(
                    f"QAM {label} preflight expected HTTP {expected_status}, received {response.status_code}"
                )
            if label == "health":
                try:
                    health = response.json()
                except ValueError as error:
                    raise RuntimeError("QAM health preflight returned non-JSON") from error
                if health != {"status": "ok"}:
                    raise RuntimeError("QAM health preflight returned an unexpected contract")
        finally:
            response.close()


def _wait_for_application(
    arm: AzureJsonClient,
    config: FoundryConfig,
    *,
    timeout_seconds: float = _PROVISIONING_TIMEOUT_SECONDS,
    poll_interval_seconds: float = _POLL_INTERVAL_SECONDS,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            application = arm.request("GET", config.application_url, scope=ARM_SCOPE)
        except AzureRequestError as error:
            if error.status_code != 404 or timeout_seconds <= 0:
                raise
            _wait_for_next_poll(
                deadline,
                poll_interval_seconds,
                "Agent Application identity did not become ready within the five-minute poll",
                error,
            )
            continue
        properties = application.get("properties")
        state = properties.get("provisioningState") if isinstance(properties, dict) else None
        if state in _TERMINAL_FAILURES:
            raise RuntimeError(f"Agent Application entered terminal state {state}")
        if (
            state == "Succeeded"
            and _application_identity(application) is not None
            and _application_contract_matches(application, config)
        ):
            return application
        _wait_for_next_poll(
            deadline,
            poll_interval_seconds,
            "Agent Application identity did not become ready within the five-minute poll",
        )


def _wait_for_deployment(
    arm: AzureJsonClient,
    config: FoundryConfig,
    expected_version: str,
    *,
    timeout_seconds: float = _PROVISIONING_TIMEOUT_SECONDS,
    poll_interval_seconds: float = _POLL_INTERVAL_SECONDS,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            deployment = arm.request("GET", config.deployment_url, scope=ARM_SCOPE)
        except AzureRequestError as error:
            if error.status_code != 404 or timeout_seconds <= 0:
                raise
            _wait_for_next_poll(
                deadline,
                poll_interval_seconds,
                "Agent Application deployment did not become ready within the five-minute poll",
                error,
            )
            continue
        properties = deployment.get("properties")
        if not isinstance(properties, dict):
            raise RuntimeError("Agent Application deployment returned no properties")
        provisioning = properties.get("provisioningState")
        state = properties.get("state")
        if provisioning in _TERMINAL_FAILURES or state in _TERMINAL_FAILURES:
            raise RuntimeError(f"Agent Application deployment entered terminal state {provisioning or state}")
        agents = properties.get("agents")
        matches = (
            isinstance(agents, list)
            and len(agents) == 1
            and isinstance(agents[0], dict)
            and agents[0].get("agentName") == config.agent_name
            and str(agents[0].get("agentVersion")) == expected_version
        )
        if provisioning == "Succeeded" and state == "Running" and matches:
            return deployment
        _wait_for_next_poll(
            deadline,
            poll_interval_seconds,
            "Agent Application deployment did not become ready within the five-minute poll",
        )


def _wait_for_next_poll(
    deadline: float,
    poll_interval_seconds: float,
    timeout_message: str,
    cause: BaseException | None = None,
) -> None:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError(timeout_message) from cause
    time.sleep(min(poll_interval_seconds, remaining))


def _registration_identity(registration: dict[str, Any], config: FoundryConfig) -> tuple[str, str]:
    if registration.get("phase") != "published-identity":
        raise ValueError("registration file is not a published-identity result")
    expected_fields = {
        "agentName": config.agent_name,
        "applicationName": config.application_name,
        "deploymentName": config.deployment_name,
        "connectionName": config.connection_name,
        "mcpAudience": config.mcp_audience,
    }
    for field, expected in expected_fields.items():
        if registration.get(field) != expected:
            raise ValueError(f"registration {field} does not match the requested configuration")
    resource_id = registration.get("applicationResourceId")
    if not isinstance(resource_id, str) or resource_id.rstrip("/").casefold() != (
        config.application_resource_id.casefold()
    ):
        raise ValueError("registration application resource ID does not match the Foundry project")
    project_resource_id = registration.get("projectResourceId")
    if not isinstance(project_resource_id, str) or project_resource_id.rstrip("/").casefold() != (
        config.project_resource_id.rstrip("/").casefold()
    ):
        raise ValueError("registration project resource ID does not match the Foundry project")
    if registration.get("applicationOpenAIBaseUrl") != config.application_openai_base_url:
        raise ValueError("registration application endpoint does not match the Foundry project")

    contract = registration.get("accessContract")
    if (
        not isinstance(contract, dict)
        or contract.get("requiredAppRole") != "Qam.Read"
        or contract.get("identitySource") != "AgentApplication.defaultInstanceIdentity"
    ):
        raise ValueError("registration does not bind Qam.Read to the Agent Application identity")
    identity = _application_identity(
        {
            "properties": {
                "defaultInstanceIdentity": {
                    "kind": "AgentInstance",
                    "clientId": registration.get("applicationClientId"),
                    "principalId": registration.get("applicationPrincipalId"),
                }
            }
        }
    )
    if identity is None:
        raise ValueError("registration has no complete Agent Application identity")
    if contract.get("allowedClientApplicationIds") != [identity[0]]:
        raise ValueError("registration client allowlist does not match the application identity")
    if contract.get("allowedPrincipalIds") != [identity[1]]:
        raise ValueError("registration principal allowlist does not match the application identity")
    return identity


def _application_identity(application: Any) -> tuple[str, str] | None:
    if not isinstance(application, dict):
        return None
    properties = application.get("properties")
    if not isinstance(properties, dict):
        return None
    identity = properties.get("defaultInstanceIdentity")
    if not isinstance(identity, dict) or identity.get("kind") != "AgentInstance":
        return None
    client_id = identity.get("clientId")
    principal_id = identity.get("principalId")
    if not _is_uuid(client_id) or not _is_uuid(principal_id):
        return None
    return client_id, principal_id


def _application_contract_matches(application: dict[str, Any], config: FoundryConfig) -> bool:
    properties = application.get("properties")
    if not isinstance(properties, dict):
        return False
    agents = properties.get("agents")
    authorization = properties.get("authorizationPolicy")
    return (
        isinstance(agents, list)
        and len(agents) == 1
        and isinstance(agents[0], dict)
        and agents[0].get("agentName") == config.agent_name
        and isinstance(authorization, dict)
        and authorization.get("authorizationScheme") == "Default"
    )


def _is_uuid(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        return False
    return str(parsed) == value.lower()


def _normalized_uuid(value: Any) -> str | None:
    if not _is_uuid(value):
        return None
    return str(uuid.UUID(value))


def _required_receipt_uuid(receipt: dict[str, Any], field: str) -> str:
    normalized = _normalized_uuid(receipt.get(field))
    if normalized is None:
        raise ValueError(f"access receipt {field} must be a UUID")
    return normalized


def _normalized_graph_object_key(value: Any) -> str | None:
    """Accept Graph's opaque URL-safe keys, including base64url app-role assignment IDs."""
    if not isinstance(value, str) or _GRAPH_OBJECT_KEY.fullmatch(value) is None:
        return None
    return _normalized_uuid(value) or value


def _required_graph_object_key(receipt: dict[str, Any], field: str) -> str:
    normalized = _normalized_graph_object_key(receipt.get(field))
    if normalized is None:
        raise ValueError(f"access receipt {field} must be a URL-safe Microsoft Graph object key")
    return normalized


def _uuid_list_matches(actual: Any, expected: list[str]) -> bool:
    if not isinstance(actual, list) or len(actual) != len(expected):
        return False
    return [_normalized_uuid(value) for value in actual] == [_normalized_uuid(value) for value in expected]


def _created_version(created: Any, config: FoundryConfig, *, expected_tools: tuple[str, ...]) -> str:
    version = getattr(created, "version", None)
    if not isinstance(version, str) or not version or len(version) > 100:
        raise RuntimeError("Foundry did not return a valid immutable agent version")
    definition = getattr(created, "definition", None)
    tools = getattr(definition, "tools", None)
    if getattr(definition, "model", None) != config.model or not isinstance(tools, list):
        raise RuntimeError("Foundry did not return the persisted agent definition")
    if not expected_tools:
        if tools:
            raise RuntimeError("published identity version unexpectedly contains tools")
        return version
    if len(tools) != 1:
        raise RuntimeError("MCP-enabled agent version does not contain exactly one tool")
    tool = tools[0]
    allowed_tools = _persisted_allowed_tool_names(tool)
    if (
        getattr(tool, "type", None) != "mcp"
        or getattr(tool, "server_label", None) != "qam"
        or getattr(tool, "server_url", None) != config.mcp_url
        or getattr(tool, "project_connection_id", None) != config.connection_name
        or getattr(tool, "require_approval", None) != "never"
        or allowed_tools != expected_tools
        or getattr(tool, "authorization", None) is not None
        or getattr(tool, "headers", None) not in (None, {})
    ):
        raise RuntimeError("persisted MCP tool does not match the exact seven-tool read-only contract")
    return version


def _persisted_allowed_tool_names(tool: Any) -> tuple[str, ...] | None:
    """Normalize only exact pinned-SDK request and persisted response shapes."""
    from azure.ai.projects.models import MCPToolFilter

    allowed = getattr(tool, "allowed_tools", None)
    if type(allowed) is list:
        names = allowed
    elif type(allowed) is MCPToolFilter:
        if allowed.read_only is not None:
            return None
        names = getattr(allowed, "tool_names", None)
    else:
        return None
    if type(names) is not list or not all(type(name) is str for name in names):
        return None
    return tuple(names)


def _write_result(result: dict[str, object], output: Path | None) -> None:
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(rendered)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")


def _dry_run(config: FoundryConfig, phase: str) -> dict[str, object]:
    version = "<created-agent-version>"
    result: dict[str, object] = {
        "mutation": False,
        "phase": phase,
        "agentUrl": config.agents_url,
        "applicationUrl": config.application_url,
        "deploymentUrl": config.deployment_url,
        "applicationResponsesUrl": config.application_responses_url,
        "agentDefinition": (
            build_identity_definition(config).as_dict()
            if phase == "identity"
            else build_agent_definition(config).as_dict()
        ),
        "application": build_application_body(config, "created-agent-id"),
        "deployment": build_deployment_body(config, version),
    }
    if phase == "attach":
        result.update(
            {
                "connectionUrl": config.connection_url,
                "connection": build_connection_body(config),
            }
        )
    return result


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        config = config_from_args(args)
        if args.dry_run:
            _write_result(_dry_run(config, args.phase), args.output)
            return 0

        from azure.identity import DefaultAzureCredential

        with DefaultAzureCredential() as credential, requests.Session() as session:
            arm = AzureJsonClient(credential=credential, session=session)
            if args.phase == "identity":
                result = create_published_identity(config, credential, arm)
            else:
                if args.registration is None or not args.registration.is_file():
                    raise ValueError("attach requires --registration from the published identity phase")
                if args.access_receipt is None or not args.access_receipt.is_file():
                    raise ValueError("attach requires --access-receipt from configure-access.sh")
                registration = json.loads(args.registration.read_text(encoding="utf-8"))
                if not isinstance(registration, dict):
                    raise ValueError("registration file must contain a JSON object")
                access_receipt = json.loads(args.access_receipt.read_text(encoding="utf-8"))
                if not isinstance(access_receipt, dict):
                    raise ValueError("access receipt file must contain a JSON object")
                result = attach_mcp(config, credential, arm, registration, access_receipt, session)
        _write_result(result, args.output)
        return 0
    except (AzureRequestError, RuntimeError, ValueError) as error:
        print(f"qam-foundry-register: {error}", file=sys.stderr)
        return 2
    except Exception as error:  # Azure SDK exceptions vary by package version.
        status = safe_diagnostic(getattr(error, "status_code", "unavailable"))
        request_id = safe_diagnostic(getattr(error, "request_id", "unavailable"))
        print(
            f"qam-foundry-register: cloud request failed; type={type(error).__name__}; "
            f"status={status}; request-id={request_id}",
            file=sys.stderr,
        )
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
