"""Fail-closed cleanup for the QAM ProjectManagedIdentity migration."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import requests

from .contracts import ALLOWED_TOOLS, SMOKE_REQUIRED_TOOLS, validate_commit_sha
from .http import AzureJsonClient, AzureRequestError, safe_diagnostic

ARM_SCOPE = "https://management.azure.com/.default"
GRAPH_SCOPE = "https://graph.microsoft.com/.default"
APPLICATION_API_VERSION = "2026-05-15-preview"
CONNECTION_API_VERSION = "2025-10-01-preview"
PROJECT_API_VERSION = "2025-06-01"
ACCESS_RECEIPT_VERSION = "qam-foundry-access/2.0"
CLEANUP_RECEIPT_VERSION = "qam-foundry-project-mi-cleanup/1.0"
SMOKE_RECEIPT_VERSION = "qam-foundry-smoke/1.0"
ACTIVE_CONNECTION_NAME = "qam-mcp-project-identity"
STALE_CONNECTION_NAME = "qam-mcp-agent-identity"
APPLICATION_IDENTITY_SOURCE = "AgentApplication.defaultInstanceIdentity"
PROJECT_IDENTITY_SOURCE = "FoundryProject.identity.systemAssigned"
CALLER_IDENTITY_TYPE = "ProjectManagedIdentity"
REQUIRED_APP_ROLE = "Qam.Read"
_MAX_RECEIPT_BYTES = 1_048_576
_MAX_GRAPH_PAGES = 20
_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")
_SAFE_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_GRAPH_OBJECT_KEY = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
_PROJECT_RESOURCE_ID = re.compile(
    r"^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]{1,90}/providers/"
    r"Microsoft\.CognitiveServices/accounts/[A-Za-z0-9-]{1,64}/projects/[A-Za-z0-9._-]{1,64}$",
    re.IGNORECASE,
)


class CleanupValidationError(ValueError):
    """Cleanup evidence or live state is not uniquely safe to mutate."""


@dataclass(frozen=True)
class CleanupContract:
    expected_commit: str
    agent_name: str
    agent_version: str
    application_name: str
    deployment_name: str
    project_resource_id: str
    application_resource_id: str
    application_client_id: str
    application_principal_id: str
    project_client_id: str
    project_principal_id: str
    mcp_url: str
    mcp_audience: str
    mcp_api_client_id: str
    mcp_api_application_object_id: str
    mcp_api_principal_id: str
    qam_read_app_role_id: str
    qam_read_assignment_id: str
    container_app_resource_id: str
    smoke_sha256: str
    access_sha256: str
    registration_sha256: str


@dataclass(frozen=True)
class Assignment:
    assignment_id: str
    principal_id: str
    resource_id: str
    app_role_id: str


@dataclass(frozen=True)
class AssignmentState:
    project_assignments: tuple[Assignment, ...]
    application_assignments: tuple[Assignment, ...]


@dataclass(frozen=True)
class CleanupPreflight:
    assignment_state: AssignmentState
    stale_connection_present: bool


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "After a passed Foundry smoke test, remove only the superseded Agent Application "
            "Qam.Read grant and qam-mcp-agent-identity connection. The command first proves the "
            "new ProjectManagedIdentity connection and grant, then verifies the final state."
        )
    )
    parser.add_argument(
        "--smoke-receipt",
        type=Path,
        default=os.getenv("QAM_FOUNDRY_SMOKE_RECEIPT"),
        help="Passed qam-foundry-smoke JSON receipt",
    )
    parser.add_argument(
        "--access-receipt",
        type=Path,
        default=os.getenv("QAM_FOUNDRY_ACCESS_RECEIPT"),
        help="qam-foundry-access/2.0 JSON receipt",
    )
    parser.add_argument(
        "--registration",
        type=Path,
        default=os.getenv("QAM_FOUNDRY_ATTACHED_REGISTRATION"),
        help="Attached-phase qam-foundry-register JSON result",
    )
    parser.add_argument(
        "--expected-commit",
        default=os.getenv("QAM_EXPECTED_COMMIT_SHA"),
        help="Exact lowercase 40- or 64-character commit proved by the smoke receipt",
    )
    parser.add_argument("--output", type=Path, help="Write the non-secret cleanup receipt as JSON")
    return parser


def _required_path(path: Path | None, option: str) -> Path:
    if path is None:
        raise CleanupValidationError(f"{option} is required")
    if not path.is_file():
        raise CleanupValidationError(f"{option} must identify an existing file")
    if path.stat().st_size > _MAX_RECEIPT_BYTES:
        raise CleanupValidationError(f"{option} exceeds the receipt size limit")
    return path


def _json_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CleanupValidationError("receipt JSON contains a duplicate object key")
        result[key] = value
    return result


def load_receipt(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_json_without_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CleanupValidationError(f"{label} is not readable JSON") from error
    if not isinstance(payload, dict):
        raise CleanupValidationError(f"{label} must contain one JSON object")
    return payload


def _canonical_digest(payload: dict[str, Any]) -> str:
    rendered = json.dumps(payload, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(rendered.encode("utf-8")).hexdigest()


def _required_text(payload: dict[str, Any], field: str, label: str) -> str:
    value = payload.get(field)
    if not isinstance(value, str) or not value or value != value.strip() or any(c in value for c in "\r\n\0"):
        raise CleanupValidationError(f"{label} {field} is missing or malformed")
    return value


def _required_uuid(payload: dict[str, Any], field: str, label: str) -> str:
    value = _required_text(payload, field, label)
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise CleanupValidationError(f"{label} {field} is not a UUID") from error
    if parsed.int == 0 or str(parsed).casefold() != value.casefold():
        raise CleanupValidationError(f"{label} {field} must not be the nil UUID")
    return str(parsed)


def _required_graph_key(payload: dict[str, Any], field: str, label: str) -> str:
    value = _required_text(payload, field, label)
    if not _GRAPH_OBJECT_KEY.fullmatch(value):
        raise CleanupValidationError(f"{label} {field} is not a safe Microsoft Graph object key")
    return value


def _expect_text(payload: dict[str, Any], field: str, expected: str, label: str) -> None:
    if payload.get(field) != expected:
        raise CleanupValidationError(f"{label} {field} does not match the cleanup contract")


def _normalize_uuid_list(value: object, label: str) -> list[str]:
    if not isinstance(value, list):
        raise CleanupValidationError(f"{label} must be a UUID list")
    result: list[str] = []
    for item in value:
        try:
            parsed = uuid.UUID(item) if isinstance(item, str) else None
        except ValueError as error:
            raise CleanupValidationError(f"{label} contains a malformed UUID") from error
        if parsed is None or parsed.int == 0 or str(parsed).casefold() != item.casefold():
            raise CleanupValidationError(f"{label} contains a malformed UUID")
        result.append(str(parsed))
    return result


def _validate_mcp_url(value: str) -> None:
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or parsed.hostname is None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port not in {None, 443}
        or parsed.path.rstrip("/") != "/mcp"
        or parsed.query
        or parsed.fragment
    ):
        raise CleanupValidationError("MCP URL does not identify one HTTPS /mcp endpoint")


def validate_cleanup_inputs(
    smoke: dict[str, Any],
    access: dict[str, Any],
    registration: dict[str, Any],
    expected_commit: str,
) -> CleanupContract:
    """Bind the three receipts and commit before any cloud request is made."""
    commit = validate_commit_sha(expected_commit)
    if access.get("receiptVersion") != ACCESS_RECEIPT_VERSION or access.get("phase") != "access-configured":
        raise CleanupValidationError("access receipt is not qam-foundry-access/2.0 access-configured")
    if (
        registration.get("phase") != "attached"
        or registration.get("accessReceiptVersion") != ACCESS_RECEIPT_VERSION
    ):
        raise CleanupValidationError("registration is not attached with qam-foundry-access/2.0")

    application_name = _required_text(access, "applicationName", "access receipt")
    agent_name = _required_text(access, "agentName", "access receipt")
    deployment_name = _required_text(registration, "deploymentName", "registration")
    agent_version = _required_text(registration, "agentVersion", "registration")
    for value, field in (
        (application_name, "applicationName"),
        (agent_name, "agentName"),
        (deployment_name, "deploymentName"),
    ):
        if not _SAFE_NAME.fullmatch(value):
            raise CleanupValidationError(f"cleanup {field} is not a safe resource name")
    if not _SAFE_VERSION.fullmatch(agent_version):
        raise CleanupValidationError("registration agentVersion is malformed")

    project_resource_id = _required_text(access, "projectResourceId", "access receipt")
    application_resource_id = _required_text(access, "applicationResourceId", "access receipt")
    if not _PROJECT_RESOURCE_ID.fullmatch(project_resource_id):
        raise CleanupValidationError("access receipt projectResourceId has an unexpected shape")
    expected_application_id = f"{project_resource_id}/applications/{application_name}"
    if application_resource_id.casefold() != expected_application_id.casefold():
        raise CleanupValidationError("access receipt applicationResourceId is not under the exact project")

    application_client_id = _required_uuid(access, "applicationClientId", "access receipt")
    application_principal_id = _required_uuid(access, "applicationPrincipalId", "access receipt")
    project_client_id = _required_uuid(access, "projectManagedIdentityClientId", "access receipt")
    project_principal_id = _required_uuid(access, "projectManagedIdentityPrincipalId", "access receipt")
    if application_client_id == project_client_id or application_principal_id == project_principal_id:
        raise CleanupValidationError("Agent Application and Foundry project identities are not distinct")

    _expect_text(access, "applicationIdentitySource", APPLICATION_IDENTITY_SOURCE, "access receipt")
    _expect_text(access, "callerIdentitySource", PROJECT_IDENTITY_SOURCE, "access receipt")
    _expect_text(access, "callerIdentityType", CALLER_IDENTITY_TYPE, "access receipt")
    if _required_uuid(access, "callerClientId", "access receipt") != project_client_id:
        raise CleanupValidationError("access receipt caller client ID is not the project identity")
    if _required_uuid(access, "callerPrincipalId", "access receipt") != project_principal_id:
        raise CleanupValidationError("access receipt caller principal ID is not the project identity")
    if _normalize_uuid_list(access.get("allowedClientApplicationIds"), "allowedClientApplicationIds") != [
        project_client_id
    ]:
        raise CleanupValidationError("access receipt does not allow exactly the project client ID")
    if _normalize_uuid_list(access.get("allowedPrincipalIds"), "allowedPrincipalIds") != [
        project_principal_id
    ]:
        raise CleanupValidationError("access receipt does not allow exactly the project principal ID")

    mcp_url = _required_text(access, "mcpUrl", "access receipt")
    _validate_mcp_url(mcp_url)
    mcp_api_client_id = _required_uuid(access, "mcpApiClientId", "access receipt")
    mcp_api_application_object_id = _required_uuid(access, "mcpApiApplicationObjectId", "access receipt")
    mcp_api_principal_id = _required_uuid(access, "mcpApiPrincipalId", "access receipt")
    qam_read_app_role_id = _required_uuid(access, "qamReadAppRoleId", "access receipt")
    qam_read_assignment_id = _required_graph_key(access, "qamReadAssignmentId", "access receipt")
    mcp_audience = _required_text(access, "mcpApiAudience", "access receipt")
    if mcp_audience.casefold() != f"api://{mcp_api_client_id}".casefold():
        raise CleanupValidationError("access receipt audience does not match the MCP API")
    if access.get("mcpRequestedAccessTokenVersion") != 2:
        raise CleanupValidationError("access receipt does not require MCP access-token version 2")
    _expect_text(access, "requiredAppRole", REQUIRED_APP_ROLE, "access receipt")
    container_app_resource_id = _required_text(access, "containerAppResourceId", "access receipt")

    registration_text_fields = {
        "agentName": agent_name,
        "applicationName": application_name,
        "deploymentName": deployment_name,
        "projectResourceId": project_resource_id,
        "applicationResourceId": application_resource_id,
        "mcpUrl": mcp_url,
        "mcpAudience": mcp_audience,
        "containerAppResourceId": container_app_resource_id,
        "applicationIdentitySource": APPLICATION_IDENTITY_SOURCE,
        "projectManagedIdentitySource": PROJECT_IDENTITY_SOURCE,
        "connectionName": ACTIVE_CONNECTION_NAME,
    }
    for field, expected in registration_text_fields.items():
        _expect_text(registration, field, expected, "registration")
    for field, expected in {
        "applicationClientId": application_client_id,
        "applicationPrincipalId": application_principal_id,
        "projectManagedIdentityClientId": project_client_id,
        "projectManagedIdentityPrincipalId": project_principal_id,
    }.items():
        if _required_uuid(registration, field, "registration") != expected:
            raise CleanupValidationError(f"registration {field} does not match the access receipt")
    if registration.get("allowedTools") != list(ALLOWED_TOOLS):
        raise CleanupValidationError("registration does not contain the exact read-only tool allowlist")

    smoke_version = smoke.get("receiptVersion")
    if smoke_version is not None and smoke_version != SMOKE_RECEIPT_VERSION:
        raise CleanupValidationError("smoke receipt has an unsupported version")
    if smoke.get("status") != "passed" or smoke.get("contentMarkerVerified") is not True:
        raise CleanupValidationError("smoke receipt is not a passed content proof")
    _expect_text(smoke, "applicationName", application_name, "smoke receipt")
    if smoke.get("toolEvents") != [f"qam.{name}" for name in SMOKE_REQUIRED_TOOLS]:
        raise CleanupValidationError("smoke receipt does not prove the exact MCP acceptance sequence")
    if smoke.get("verifiedCommit") != commit:
        raise CleanupValidationError("smoke receipt commit does not match --expected-commit")
    _required_text(smoke, "responseId", "smoke receipt")

    return CleanupContract(
        expected_commit=commit,
        agent_name=agent_name,
        agent_version=agent_version,
        application_name=application_name,
        deployment_name=deployment_name,
        project_resource_id=project_resource_id,
        application_resource_id=application_resource_id,
        application_client_id=application_client_id,
        application_principal_id=application_principal_id,
        project_client_id=project_client_id,
        project_principal_id=project_principal_id,
        mcp_url=mcp_url,
        mcp_audience=mcp_audience,
        mcp_api_client_id=mcp_api_client_id,
        mcp_api_application_object_id=mcp_api_application_object_id,
        mcp_api_principal_id=mcp_api_principal_id,
        qam_read_app_role_id=qam_read_app_role_id,
        qam_read_assignment_id=qam_read_assignment_id,
        container_app_resource_id=container_app_resource_id,
        smoke_sha256=_canonical_digest(smoke),
        access_sha256=_canonical_digest(access),
        registration_sha256=_canonical_digest(registration),
    )


def _arm_url(resource_id: str, api_version: str) -> str:
    return f"https://management.azure.com{resource_id}?api-version={api_version}"


def _connection_resource_id(contract: CleanupContract, name: str) -> str:
    return f"{contract.project_resource_id}/connections/{name}"


def _connection_url(contract: CleanupContract, name: str) -> str:
    return _arm_url(_connection_resource_id(contract, name), CONNECTION_API_VERSION)


def _get_optional(client: AzureJsonClient, url: str, *, scope: str) -> dict[str, Any] | None:
    try:
        return client.request("GET", url, scope=scope)
    except AzureRequestError as error:
        if error.status_code == 404:
            return None
        raise


def _assert_resource_identity(payload: dict[str, Any], resource_id: str, name: str, label: str) -> None:
    live_id = payload.get("id")
    if not isinstance(live_id, str) or live_id.rstrip("/").casefold() != resource_id.casefold():
        raise CleanupValidationError(f"live {label} resource ID does not match its receipt")
    if payload.get("name") != name:
        raise CleanupValidationError(f"live {label} name does not match its receipt")


def _verify_live_application(client: AzureJsonClient, contract: CleanupContract) -> None:
    application = client.request(
        "GET",
        _arm_url(contract.application_resource_id, APPLICATION_API_VERSION),
        scope=ARM_SCOPE,
    )
    _assert_resource_identity(
        application,
        contract.application_resource_id,
        contract.application_name,
        "application",
    )
    properties = application.get("properties")
    identity = properties.get("defaultInstanceIdentity") if isinstance(properties, dict) else None
    agents = properties.get("agents") if isinstance(properties, dict) else None
    authorization = properties.get("authorizationPolicy") if isinstance(properties, dict) else None
    if (
        not isinstance(properties, dict)
        or properties.get("provisioningState") != "Succeeded"
        or not isinstance(authorization, dict)
        or authorization.get("authorizationScheme") != "Default"
        or not isinstance(agents, list)
        or len(agents) != 1
        or not isinstance(agents[0], dict)
        or agents[0].get("agentName") != contract.agent_name
        or not isinstance(identity, dict)
        or identity.get("kind") != "AgentInstance"
        or _uuid_or_none(identity.get("clientId")) != contract.application_client_id
        or _uuid_or_none(identity.get("principalId")) != contract.application_principal_id
    ):
        raise CleanupValidationError("live Agent Application no longer matches the attached registration")

    deployment_id = f"{contract.application_resource_id}/agentdeployments/{contract.deployment_name}"
    deployment = client.request(
        "GET",
        _arm_url(deployment_id, APPLICATION_API_VERSION),
        scope=ARM_SCOPE,
    )
    _assert_resource_identity(deployment, deployment_id, contract.deployment_name, "agent deployment")
    deployment_properties = deployment.get("properties")
    deployment_agents = (
        deployment_properties.get("agents") if isinstance(deployment_properties, dict) else None
    )
    protocols = deployment_properties.get("protocols") if isinstance(deployment_properties, dict) else None
    if (
        not isinstance(deployment_properties, dict)
        or deployment_properties.get("provisioningState") != "Succeeded"
        or deployment_properties.get("state") != "Running"
        or deployment_properties.get("deploymentType") != "Managed"
        or not isinstance(deployment_agents, list)
        or len(deployment_agents) != 1
        or not isinstance(deployment_agents[0], dict)
        or deployment_agents[0].get("agentName") != contract.agent_name
        or deployment_agents[0].get("agentVersion") != contract.agent_version
        or protocols != [{"protocol": "Responses", "version": "1.0"}]
    ):
        raise CleanupValidationError("live deployment is not the exact running attached agent version")


def _uuid_or_none(value: object) -> str | None:
    try:
        return str(uuid.UUID(value)) if isinstance(value, str) else None
    except ValueError:
        return None


def _verify_service_principal(
    client: AzureJsonClient,
    *,
    principal_id: str,
    client_id: str,
    managed_identity: bool,
) -> None:
    principal = client.request(
        "GET",
        (
            f"https://graph.microsoft.com/v1.0/servicePrincipals/{principal_id}"
            "?$select=id,appId,servicePrincipalType"
        ),
        scope=GRAPH_SCOPE,
    )
    if (
        _uuid_or_none(principal.get("id")) != principal_id
        or _uuid_or_none(principal.get("appId")) != client_id
        or (managed_identity and principal.get("servicePrincipalType") != "ManagedIdentity")
    ):
        raise CleanupValidationError("live caller service principal does not match its receipt")


def _verify_live_project(client: AzureJsonClient, contract: CleanupContract) -> None:
    project = client.request(
        "GET",
        _arm_url(contract.project_resource_id, PROJECT_API_VERSION),
        scope=ARM_SCOPE,
    )
    live_id = project.get("id")
    identity = project.get("identity")
    properties = project.get("properties")
    if (
        not isinstance(live_id, str)
        or live_id.rstrip("/").casefold() != contract.project_resource_id.casefold()
        or not isinstance(properties, dict)
        or properties.get("provisioningState") != "Succeeded"
        or not isinstance(identity, dict)
        or identity.get("type") != "SystemAssigned"
        or _uuid_or_none(identity.get("principalId")) != contract.project_principal_id
        or _uuid_or_none(identity.get("tenantId")) is None
    ):
        raise CleanupValidationError("live Foundry project identity no longer matches its receipt")
    _verify_service_principal(
        client,
        principal_id=contract.project_principal_id,
        client_id=contract.project_client_id,
        managed_identity=True,
    )
    _verify_service_principal(
        client,
        principal_id=contract.application_principal_id,
        client_id=contract.application_client_id,
        managed_identity=False,
    )


def _verify_mcp_api(client: AzureJsonClient, contract: CleanupContract) -> None:
    application = client.request(
        "GET",
        (
            f"https://graph.microsoft.com/v1.0/applications/{contract.mcp_api_application_object_id}"
            "?$select=id,appId,appRoles,api"
        ),
        scope=GRAPH_SCOPE,
    )
    roles = application.get("appRoles")
    qam_roles = (
        [role for role in roles if isinstance(role, dict) and role.get("value") == REQUIRED_APP_ROLE]
        if isinstance(roles, list)
        else []
    )
    api = application.get("api")
    if (
        _uuid_or_none(application.get("id")) != contract.mcp_api_application_object_id
        or _uuid_or_none(application.get("appId")) != contract.mcp_api_client_id
        or not isinstance(api, dict)
        or api.get("requestedAccessTokenVersion") != 2
        or len(qam_roles) != 1
        or _uuid_or_none(qam_roles[0].get("id")) != contract.qam_read_app_role_id
        or qam_roles[0].get("isEnabled") is not True
        or qam_roles[0].get("allowedMemberTypes") != ["Application"]
    ):
        raise CleanupValidationError("live MCP API does not expose the exact Qam.Read contract")

    principal = client.request(
        "GET",
        (
            f"https://graph.microsoft.com/v1.0/servicePrincipals/{contract.mcp_api_principal_id}"
            "?$select=id,appId,appRoleAssignmentRequired"
        ),
        scope=GRAPH_SCOPE,
    )
    if (
        _uuid_or_none(principal.get("id")) != contract.mcp_api_principal_id
        or _uuid_or_none(principal.get("appId")) != contract.mcp_api_client_id
        or principal.get("appRoleAssignmentRequired") is not True
    ):
        raise CleanupValidationError(
            "live MCP API principal is not the assignment-required receipt principal"
        )


def _validate_connection(
    payload: dict[str, Any],
    contract: CleanupContract,
    *,
    name: str,
    allowed_auth_types: set[str],
) -> None:
    resource_id = _connection_resource_id(contract, name)
    _assert_resource_identity(payload, resource_id, name, "project connection")
    if str(payload.get("type", "")).casefold() != (
        "Microsoft.CognitiveServices/accounts/projects/connections".casefold()
    ):
        raise CleanupValidationError("live project connection has an unexpected resource type")
    properties = payload.get("properties")
    credentials = properties.get("credentials") if isinstance(properties, dict) else None
    metadata = properties.get("metadata") if isinstance(properties, dict) else None
    if (
        not isinstance(properties, dict)
        or properties.get("authType") not in allowed_auth_types
        or properties.get("category") != "RemoteTool"
        or properties.get("target") != contract.mcp_url
        or properties.get("audience") != contract.mcp_audience
        or (credentials is not None and credentials != "" and credentials != {})
        or properties.get("error") is not None
        or not isinstance(metadata, dict)
        or metadata.get("ApiType") != "Azure"
        or metadata.get("type") != "generic_mcp"
    ):
        raise CleanupValidationError("live project connection does not match the exact MCP contract")


def _graph_collection(client: AzureJsonClient, url: str) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    current: str | None = url
    for _ in range(_MAX_GRAPH_PAGES):
        if current is None:
            return items
        if current in seen:
            raise CleanupValidationError("Microsoft Graph returned a repeated collection page")
        parsed = urlsplit(current)
        if (
            parsed.scheme != "https"
            or parsed.hostname != "graph.microsoft.com"
            or parsed.port not in {None, 443}
            or parsed.username is not None
            or parsed.password is not None
            or not parsed.path.startswith("/v1.0/")
            or parsed.fragment
        ):
            raise CleanupValidationError("Microsoft Graph returned an unsafe collection continuation")
        seen.add(current)
        page = client.request("GET", current, scope=GRAPH_SCOPE)
        values = page.get("value")
        if not isinstance(values, list) or not all(isinstance(item, dict) for item in values):
            raise CleanupValidationError("Microsoft Graph returned a malformed assignment collection")
        items.extend(values)
        next_link = page.get("@odata.nextLink")
        if next_link is not None and not isinstance(next_link, str):
            raise CleanupValidationError("Microsoft Graph returned a malformed collection continuation")
        current = next_link
    raise CleanupValidationError("Microsoft Graph assignment collection exceeded the page limit")


def _parse_assignments(values: list[dict[str, Any]], label: str) -> list[Assignment]:
    assignments: list[Assignment] = []
    ids: set[str] = set()
    for value in values:
        assignment_id = value.get("id")
        principal_id = _uuid_or_none(value.get("principalId"))
        resource_id = _uuid_or_none(value.get("resourceId"))
        app_role_id = _uuid_or_none(value.get("appRoleId"))
        if (
            not isinstance(assignment_id, str)
            or not _GRAPH_OBJECT_KEY.fullmatch(assignment_id)
            or principal_id is None
            or resource_id is None
            or app_role_id is None
            or assignment_id in ids
        ):
            raise CleanupValidationError(f"{label} contains a malformed or duplicate assignment")
        ids.add(assignment_id)
        assignments.append(Assignment(assignment_id, principal_id, resource_id, app_role_id))
    return assignments


def _read_assignment_state(client: AzureJsonClient, contract: CleanupContract) -> AssignmentState:
    select = "?$select=id,appRoleId,principalId,resourceId"
    resource_values = _graph_collection(
        client,
        (
            f"https://graph.microsoft.com/v1.0/servicePrincipals/{contract.mcp_api_principal_id}"
            f"/appRoleAssignedTo{select}"
        ),
    )
    application_values = _graph_collection(
        client,
        (
            f"https://graph.microsoft.com/v1.0/servicePrincipals/{contract.application_principal_id}"
            f"/appRoleAssignments{select}"
        ),
    )
    project_values = _graph_collection(
        client,
        (
            f"https://graph.microsoft.com/v1.0/servicePrincipals/{contract.project_principal_id}"
            f"/appRoleAssignments{select}"
        ),
    )
    resource_assignments = _parse_assignments(resource_values, "MCP API assignment list")
    application_assignments = _parse_assignments(application_values, "Agent Application assignment list")
    project_assignments = _parse_assignments(project_values, "project identity assignment list")

    if any(item.resource_id != contract.mcp_api_principal_id for item in resource_assignments):
        raise CleanupValidationError("MCP API assignment list contains a foreign resource")
    if any(item.principal_id != contract.application_principal_id for item in application_assignments):
        raise CleanupValidationError("Agent Application assignment list contains a foreign principal")
    if any(item.principal_id != contract.project_principal_id for item in project_assignments):
        raise CleanupValidationError("project identity assignment list contains a foreign principal")

    relevant_resource = [
        item
        for item in resource_assignments
        if item.resource_id == contract.mcp_api_principal_id
        and item.app_role_id == contract.qam_read_app_role_id
    ]
    unknown_principals = {
        item.principal_id
        for item in relevant_resource
        if item.principal_id not in {contract.project_principal_id, contract.application_principal_id}
    }
    if unknown_principals:
        raise CleanupValidationError("Qam.Read has an unexpected principal; cleanup is ambiguous")

    project_exact = [
        item
        for item in project_assignments
        if item.principal_id == contract.project_principal_id
        and item.resource_id == contract.mcp_api_principal_id
        and item.app_role_id == contract.qam_read_app_role_id
    ]
    application_exact = [
        item
        for item in application_assignments
        if item.principal_id == contract.application_principal_id
        and item.resource_id == contract.mcp_api_principal_id
        and item.app_role_id == contract.qam_read_app_role_id
    ]
    resource_project = [
        item for item in relevant_resource if item.principal_id == contract.project_principal_id
    ]
    resource_application = [
        item for item in relevant_resource if item.principal_id == contract.application_principal_id
    ]
    if len(project_exact) != 1 or {item.assignment_id for item in project_exact} != {
        item.assignment_id for item in resource_project
    }:
        raise CleanupValidationError("Project Managed Identity does not have exactly one consistent Qam.Read")
    if project_exact[0].assignment_id != contract.qam_read_assignment_id:
        raise CleanupValidationError("live project Qam.Read assignment does not match the access receipt")
    if {item.assignment_id for item in application_exact} != {
        item.assignment_id for item in resource_application
    }:
        raise CleanupValidationError("Agent Application Qam.Read assignment views are inconsistent")
    return AssignmentState(tuple(project_exact), tuple(application_exact))


def _verify_live_immutable_contract(client: AzureJsonClient, contract: CleanupContract) -> None:
    _verify_live_application(client, contract)
    _verify_live_project(client, contract)
    _verify_mcp_api(client, contract)


def preflight_cleanup(client: AzureJsonClient, contract: CleanupContract) -> CleanupPreflight:
    """Read every safety boundary before the first DELETE."""
    _verify_live_immutable_contract(client, contract)
    active = _get_optional(client, _connection_url(contract, ACTIVE_CONNECTION_NAME), scope=ARM_SCOPE)
    if active is None:
        raise CleanupValidationError("active qam-mcp-project-identity connection does not exist")
    _validate_connection(
        active,
        contract,
        name=ACTIVE_CONNECTION_NAME,
        allowed_auth_types={CALLER_IDENTITY_TYPE},
    )
    stale = _get_optional(client, _connection_url(contract, STALE_CONNECTION_NAME), scope=ARM_SCOPE)
    if stale is not None:
        _validate_connection(
            stale,
            contract,
            name=STALE_CONNECTION_NAME,
            allowed_auth_types={"AgenticIdentityToken", CALLER_IDENTITY_TYPE},
        )
    assignment_state = _read_assignment_state(client, contract)
    return CleanupPreflight(assignment_state, stale is not None)


def _delete_assignment(client: AzureJsonClient, contract: CleanupContract, assignment: Assignment) -> bool:
    url = (
        f"https://graph.microsoft.com/v1.0/servicePrincipals/{contract.application_principal_id}"
        f"/appRoleAssignments/{assignment.assignment_id}"
    )
    try:
        client.request(
            "DELETE",
            url,
            scope=GRAPH_SCOPE,
            expected_statuses=(200, 202, 204),
            allow_empty_response=True,
        )
    except AzureRequestError as error:
        if error.status_code == 404:
            return False
        raise
    return True


def _delete_stale_connection(client: AzureJsonClient, contract: CleanupContract) -> bool:
    try:
        client.request(
            "DELETE",
            _connection_url(contract, STALE_CONNECTION_NAME),
            scope=ARM_SCOPE,
            expected_statuses=(200, 202, 204),
            allow_empty_response=True,
        )
    except AzureRequestError as error:
        if error.status_code == 404:
            return False
        raise
    return True


def _wait_for_clean_state(
    client: AzureJsonClient,
    contract: CleanupContract,
    *,
    attempts: int,
    delay_seconds: float,
    sleep: Callable[[float], None],
) -> AssignmentState:
    for attempt in range(attempts):
        state = _read_assignment_state(client, contract)
        stale = _get_optional(client, _connection_url(contract, STALE_CONNECTION_NAME), scope=ARM_SCOPE)
        if stale is not None:
            _validate_connection(
                stale,
                contract,
                name=STALE_CONNECTION_NAME,
                allowed_auth_types={"AgenticIdentityToken", CALLER_IDENTITY_TYPE},
            )
        if not state.application_assignments and stale is None:
            return state
        if attempt + 1 < attempts:
            sleep(delay_seconds)
    raise CleanupValidationError("cleanup deletes did not converge to the required final state")


def execute_cleanup(
    client: AzureJsonClient,
    contract: CleanupContract,
    *,
    attempts: int = 30,
    delay_seconds: float = 2.0,
    sleep: Callable[[float], None] = time.sleep,
) -> dict[str, object]:
    if attempts < 1 or delay_seconds < 0:
        raise ValueError("cleanup polling parameters are invalid")
    preflight = preflight_cleanup(client, contract)

    deleted_assignments = 0
    for assignment in preflight.assignment_state.application_assignments:
        if _delete_assignment(client, contract, assignment):
            deleted_assignments += 1
    deleted_connection = (
        _delete_stale_connection(client, contract) if preflight.stale_connection_present else False
    )

    final_assignments = _wait_for_clean_state(
        client,
        contract,
        attempts=attempts,
        delay_seconds=delay_seconds,
        sleep=sleep,
    )
    _verify_live_immutable_contract(client, contract)
    active = _get_optional(client, _connection_url(contract, ACTIVE_CONNECTION_NAME), scope=ARM_SCOPE)
    if active is None:
        raise CleanupValidationError("active ProjectManagedIdentity connection disappeared during cleanup")
    _validate_connection(
        active,
        contract,
        name=ACTIVE_CONNECTION_NAME,
        allowed_auth_types={CALLER_IDENTITY_TYPE},
    )
    if len(final_assignments.project_assignments) != 1 or final_assignments.application_assignments:
        raise CleanupValidationError("final Qam.Read assignment state is not least privilege")

    return {
        "receiptVersion": CLEANUP_RECEIPT_VERSION,
        "phase": "cleanup-verified",
        "status": "passed",
        "verifiedCommit": contract.expected_commit,
        "agentName": contract.agent_name,
        "agentVersion": contract.agent_version,
        "applicationName": contract.application_name,
        "applicationResourceId": contract.application_resource_id,
        "projectResourceId": contract.project_resource_id,
        "applicationPrincipalId": contract.application_principal_id,
        "projectManagedIdentityPrincipalId": contract.project_principal_id,
        "mcpApiPrincipalId": contract.mcp_api_principal_id,
        "qamReadAppRoleId": contract.qam_read_app_role_id,
        "activeConnectionName": ACTIVE_CONNECTION_NAME,
        "activeConnectionAuthType": CALLER_IDENTITY_TYPE,
        "staleConnectionName": STALE_CONNECTION_NAME,
        "staleConnectionPresentBefore": preflight.stale_connection_present,
        "staleConnectionDeleteCompleted": deleted_connection,
        "staleApplicationAssignmentsBefore": len(preflight.assignment_state.application_assignments),
        "staleApplicationAssignmentDeletesCompleted": deleted_assignments,
        "finalProjectManagedIdentityQamReadCount": len(final_assignments.project_assignments),
        "finalAgentApplicationQamReadCount": len(final_assignments.application_assignments),
        "mutationPerformed": deleted_assignments > 0 or deleted_connection,
        "inputEvidenceSha256": {
            "smoke": contract.smoke_sha256,
            "access": contract.access_sha256,
            "registration": contract.registration_sha256,
        },
    }


def _write_result(result: dict[str, object], output: Path | None) -> None:
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(rendered)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        smoke_path = _required_path(args.smoke_receipt, "--smoke-receipt")
        access_path = _required_path(args.access_receipt, "--access-receipt")
        registration_path = _required_path(args.registration, "--registration")
        if args.expected_commit is None:
            raise CleanupValidationError("--expected-commit is required")
        if args.output is not None:
            output = args.output.resolve(strict=False)
            if output in {
                smoke_path.resolve(),
                access_path.resolve(),
                registration_path.resolve(),
            }:
                raise CleanupValidationError("--output must not overwrite an input receipt")
        contract = validate_cleanup_inputs(
            load_receipt(smoke_path, "smoke receipt"),
            load_receipt(access_path, "access receipt"),
            load_receipt(registration_path, "attached registration"),
            args.expected_commit,
        )

        from azure.identity import DefaultAzureCredential

        with DefaultAzureCredential() as credential, requests.Session() as session:
            client = AzureJsonClient(credential=credential, session=session)
            result = execute_cleanup(client, contract)
        _write_result(result, args.output)
        return 0
    except (AzureRequestError, CleanupValidationError, OSError, ValueError) as error:
        print(f"qam-foundry-cleanup: {error}", file=sys.stderr)
        return 2
    except Exception as error:  # Azure SDK exceptions vary by package version.
        status = safe_diagnostic(getattr(error, "status_code", "unavailable"))
        request_id = safe_diagnostic(getattr(error, "request_id", "unavailable"))
        print(
            f"qam-foundry-cleanup: cloud request failed; type={type(error).__name__}; "
            f"status={status}; request-id={request_id}",
            file=sys.stderr,
        )
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
