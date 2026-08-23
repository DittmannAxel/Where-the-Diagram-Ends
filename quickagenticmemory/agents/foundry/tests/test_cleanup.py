from __future__ import annotations

from typing import Any

import pytest

from qam_foundry.cleanup import (
    ACCESS_RECEIPT_VERSION,
    ACTIVE_CONNECTION_NAME,
    APPLICATION_API_VERSION,
    ARM_SCOPE,
    CALLER_IDENTITY_TYPE,
    CLEANUP_RECEIPT_VERSION,
    CONNECTION_API_VERSION,
    GRAPH_SCOPE,
    PROJECT_API_VERSION,
    STALE_CONNECTION_NAME,
    CleanupValidationError,
    execute_cleanup,
    validate_cleanup_inputs,
)
from qam_foundry.contracts import ALLOWED_TOOLS, SMOKE_REQUIRED_TOOLS
from qam_foundry.http import AzureRequestError

COMMIT = "a" * 40
APPLICATION_CLIENT_ID = "11111111-1111-4111-8111-111111111111"
APPLICATION_PRINCIPAL_ID = "22222222-2222-4222-8222-222222222222"
PROJECT_CLIENT_ID = "33333333-3333-4333-8333-333333333333"
PROJECT_PRINCIPAL_ID = "44444444-4444-4444-8444-444444444444"
MCP_CLIENT_ID = "55555555-5555-4555-8555-555555555555"
MCP_APPLICATION_OBJECT_ID = "66666666-6666-4666-8666-666666666666"
MCP_PRINCIPAL_ID = "77777777-7777-4777-8777-777777777777"
QAM_ROLE_ID = "88888888-8888-4888-8888-888888888888"
OTHER_ROLE_ID = "99999999-9999-4999-8999-999999999999"
UNKNOWN_PRINCIPAL_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
PROJECT_ASSIGNMENT_ID = "project_assignment"
PROJECT_RESOURCE_ID = (
    "/subscriptions/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/resourceGroups/rg-qam-test/"
    "providers/Microsoft.CognitiveServices/accounts/qamfoundry/projects/qam-project"
)
APPLICATION_NAME = "qam-knowledge-application"
APPLICATION_RESOURCE_ID = f"{PROJECT_RESOURCE_ID}/applications/{APPLICATION_NAME}"
DEPLOYMENT_NAME = "qam-managed-deployment"
AGENT_NAME = "qam-knowledge-agent"
AGENT_VERSION = "2"
MCP_URL = "https://qam.example.azurecontainerapps.io/mcp"
MCP_AUDIENCE = f"api://{MCP_CLIENT_ID}"
CONTAINER_APP_ID = (
    "/subscriptions/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/resourceGroups/rg-qam-test/"
    "providers/Microsoft.App/containerApps/qam-mcp"
)


def smoke_receipt() -> dict[str, Any]:
    return {
        "status": "passed",
        "applicationName": APPLICATION_NAME,
        "toolEvents": [f"qam.{name}" for name in SMOKE_REQUIRED_TOOLS],
        "verifiedCommit": COMMIT,
        "contentMarkerVerified": True,
        "responseId": "resp_safe",
    }


def access_receipt() -> dict[str, Any]:
    return {
        "receiptVersion": ACCESS_RECEIPT_VERSION,
        "phase": "access-configured",
        "agentName": AGENT_NAME,
        "applicationName": APPLICATION_NAME,
        "applicationResourceId": APPLICATION_RESOURCE_ID,
        "projectResourceId": PROJECT_RESOURCE_ID,
        "applicationClientId": APPLICATION_CLIENT_ID,
        "applicationPrincipalId": APPLICATION_PRINCIPAL_ID,
        "applicationIdentitySource": "AgentApplication.defaultInstanceIdentity",
        "projectManagedIdentityClientId": PROJECT_CLIENT_ID,
        "projectManagedIdentityPrincipalId": PROJECT_PRINCIPAL_ID,
        "callerIdentitySource": "FoundryProject.identity.systemAssigned",
        "callerIdentityType": CALLER_IDENTITY_TYPE,
        "callerClientId": PROJECT_CLIENT_ID,
        "callerPrincipalId": PROJECT_PRINCIPAL_ID,
        "mcpUrl": MCP_URL,
        "mcpApiClientId": MCP_CLIENT_ID,
        "mcpApiApplicationObjectId": MCP_APPLICATION_OBJECT_ID,
        "mcpApiPrincipalId": MCP_PRINCIPAL_ID,
        "mcpApiAudience": MCP_AUDIENCE,
        "mcpRequestedAccessTokenVersion": 2,
        "qamReadAppRoleId": QAM_ROLE_ID,
        "qamReadAssignmentId": PROJECT_ASSIGNMENT_ID,
        "containerAppResourceId": CONTAINER_APP_ID,
        "requiredAppRole": "Qam.Read",
        "allowedClientApplicationIds": [PROJECT_CLIENT_ID],
        "allowedPrincipalIds": [PROJECT_PRINCIPAL_ID],
    }


def attached_registration() -> dict[str, Any]:
    return {
        "phase": "attached",
        "accessReceiptVersion": ACCESS_RECEIPT_VERSION,
        "agentName": AGENT_NAME,
        "agentVersion": AGENT_VERSION,
        "applicationName": APPLICATION_NAME,
        "applicationResourceId": APPLICATION_RESOURCE_ID,
        "projectResourceId": PROJECT_RESOURCE_ID,
        "deploymentName": DEPLOYMENT_NAME,
        "applicationClientId": APPLICATION_CLIENT_ID,
        "applicationPrincipalId": APPLICATION_PRINCIPAL_ID,
        "applicationIdentitySource": "AgentApplication.defaultInstanceIdentity",
        "projectManagedIdentityClientId": PROJECT_CLIENT_ID,
        "projectManagedIdentityPrincipalId": PROJECT_PRINCIPAL_ID,
        "projectManagedIdentitySource": "FoundryProject.identity.systemAssigned",
        "connectionName": ACTIVE_CONNECTION_NAME,
        "mcpUrl": MCP_URL,
        "mcpAudience": MCP_AUDIENCE,
        "containerAppResourceId": CONTAINER_APP_ID,
        "allowedTools": list(ALLOWED_TOOLS),
    }


def contract():
    return validate_cleanup_inputs(smoke_receipt(), access_receipt(), attached_registration(), COMMIT)


class FakeAzureClient:
    def __init__(
        self,
        *,
        stale_assignments: tuple[str, ...] = ("stale_assignment",),
        stale_connection: bool = True,
        active_connection: bool = True,
        active_auth_type: str = CALLER_IDENTITY_TYPE,
        stale_target: str = MCP_URL,
        unknown_qam_principal: bool = False,
        include_unrelated_assignment: bool = False,
    ) -> None:
        self.stale_assignments = list(stale_assignments)
        self.stale_connection = stale_connection
        self.active_connection = active_connection
        self.active_auth_type = active_auth_type
        self.stale_target = stale_target
        self.unknown_qam_principal = unknown_qam_principal
        self.include_unrelated_assignment = include_unrelated_assignment
        self.calls: list[tuple[str, str]] = []

    def request(
        self,
        method: str,
        url: str,
        *,
        scope: str,
        body: dict[str, object] | None = None,
        expected_statuses: tuple[int, ...] = (200,),
        allow_empty_response: bool = False,
    ) -> dict[str, Any]:
        del body, expected_statuses, allow_empty_response
        self.calls.append((method, url))
        if method == "DELETE":
            return self._delete(url, scope)
        if method != "GET":
            raise AssertionError(f"unexpected method {method}")
        return self._get(url, scope)

    def _delete(self, url: str, scope: str) -> dict[str, Any]:
        if scope == GRAPH_SCOPE and "/appRoleAssignments/" in url:
            assignment_id = url.rsplit("/", 1)[-1]
            if assignment_id not in self.stale_assignments:
                raise AzureRequestError("not found", status_code=404)
            self.stale_assignments.remove(assignment_id)
            return {}
        if scope == ARM_SCOPE and f"/connections/{STALE_CONNECTION_NAME}?" in url:
            if not self.stale_connection:
                raise AzureRequestError("not found", status_code=404)
            self.stale_connection = False
            return {}
        raise AssertionError(f"unexpected DELETE {url}")

    def _get(self, url: str, scope: str) -> dict[str, Any]:
        if scope == ARM_SCOPE:
            return self._get_arm(url)
        if scope == GRAPH_SCOPE:
            return self._get_graph(url)
        raise AssertionError(f"unexpected scope {scope}")

    def _get_arm(self, url: str) -> dict[str, Any]:
        if f"/connections/{ACTIVE_CONNECTION_NAME}?api-version={CONNECTION_API_VERSION}" in url:
            if not self.active_connection:
                raise AzureRequestError("not found", status_code=404)
            return self._connection(ACTIVE_CONNECTION_NAME, self.active_auth_type, MCP_URL)
        if f"/connections/{STALE_CONNECTION_NAME}?api-version={CONNECTION_API_VERSION}" in url:
            if not self.stale_connection:
                raise AzureRequestError("not found", status_code=404)
            return self._connection(STALE_CONNECTION_NAME, CALLER_IDENTITY_TYPE, self.stale_target)
        deployment_id = f"{APPLICATION_RESOURCE_ID}/agentdeployments/{DEPLOYMENT_NAME}"
        if url == f"https://management.azure.com{deployment_id}?api-version={APPLICATION_API_VERSION}":
            return {
                "id": deployment_id,
                "name": DEPLOYMENT_NAME,
                "properties": {
                    "provisioningState": "Succeeded",
                    "state": "Running",
                    "deploymentType": "Managed",
                    "agents": [
                        {
                            "agentId": None,
                            "agentName": AGENT_NAME,
                            "agentVersion": AGENT_VERSION,
                        }
                    ],
                    "protocols": [{"protocol": "Responses", "version": "1.0"}],
                },
            }
        if url == (
            f"https://management.azure.com{APPLICATION_RESOURCE_ID}?api-version={APPLICATION_API_VERSION}"
        ):
            return {
                "id": APPLICATION_RESOURCE_ID,
                "name": APPLICATION_NAME,
                "properties": {
                    "provisioningState": "Succeeded",
                    "authorizationPolicy": {"authorizationScheme": "Default"},
                    "agents": [{"agentName": AGENT_NAME}],
                    "defaultInstanceIdentity": {
                        "kind": "AgentInstance",
                        "clientId": APPLICATION_CLIENT_ID,
                        "principalId": APPLICATION_PRINCIPAL_ID,
                    },
                },
            }
        if url == (f"https://management.azure.com{PROJECT_RESOURCE_ID}?api-version={PROJECT_API_VERSION}"):
            return {
                "id": PROJECT_RESOURCE_ID,
                "properties": {"provisioningState": "Succeeded"},
                "identity": {
                    "type": "SystemAssigned",
                    "principalId": PROJECT_PRINCIPAL_ID,
                    "tenantId": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                },
            }
        raise AssertionError(f"unexpected ARM GET {url}")

    def _connection(self, name: str, auth_type: str, target: str) -> dict[str, Any]:
        return {
            "id": f"{PROJECT_RESOURCE_ID}/connections/{name}",
            "name": name,
            "type": "Microsoft.CognitiveServices/accounts/projects/connections",
            "properties": {
                "authType": auth_type,
                "category": "RemoteTool",
                "target": target,
                "audience": MCP_AUDIENCE,
                "error": None,
                "metadata": {"ApiType": "Azure", "type": "generic_mcp"},
            },
        }

    def _get_graph(self, url: str) -> dict[str, Any]:
        if f"servicePrincipals/{MCP_PRINCIPAL_ID}/appRoleAssignedTo?" in url:
            assignments = [self._assignment(PROJECT_ASSIGNMENT_ID, PROJECT_PRINCIPAL_ID, QAM_ROLE_ID)]
            assignments.extend(
                self._assignment(assignment_id, APPLICATION_PRINCIPAL_ID, QAM_ROLE_ID)
                for assignment_id in self.stale_assignments
            )
            if self.unknown_qam_principal:
                assignments.append(self._assignment("unknown_assignment", UNKNOWN_PRINCIPAL_ID, QAM_ROLE_ID))
            if self.include_unrelated_assignment:
                assignments.append(
                    self._assignment("unrelated_assignment", APPLICATION_PRINCIPAL_ID, OTHER_ROLE_ID)
                )
            return {"value": assignments}
        if f"servicePrincipals/{APPLICATION_PRINCIPAL_ID}/appRoleAssignments?" in url:
            assignments = [
                self._assignment(assignment_id, APPLICATION_PRINCIPAL_ID, QAM_ROLE_ID)
                for assignment_id in self.stale_assignments
            ]
            if self.include_unrelated_assignment:
                assignments.append(
                    self._assignment("unrelated_assignment", APPLICATION_PRINCIPAL_ID, OTHER_ROLE_ID)
                )
            return {"value": assignments}
        if f"servicePrincipals/{PROJECT_PRINCIPAL_ID}/appRoleAssignments?" in url:
            return {"value": [self._assignment(PROJECT_ASSIGNMENT_ID, PROJECT_PRINCIPAL_ID, QAM_ROLE_ID)]}
        if f"applications/{MCP_APPLICATION_OBJECT_ID}?" in url:
            return {
                "id": MCP_APPLICATION_OBJECT_ID,
                "appId": MCP_CLIENT_ID,
                "api": {"requestedAccessTokenVersion": 2},
                "appRoles": [
                    {
                        "id": QAM_ROLE_ID,
                        "value": "Qam.Read",
                        "isEnabled": True,
                        "allowedMemberTypes": ["Application"],
                    }
                ],
            }
        if f"servicePrincipals/{MCP_PRINCIPAL_ID}?" in url:
            return {
                "id": MCP_PRINCIPAL_ID,
                "appId": MCP_CLIENT_ID,
                "appRoleAssignmentRequired": True,
            }
        if f"servicePrincipals/{PROJECT_PRINCIPAL_ID}?" in url:
            return {
                "id": PROJECT_PRINCIPAL_ID,
                "appId": PROJECT_CLIENT_ID,
                "servicePrincipalType": "ManagedIdentity",
            }
        if f"servicePrincipals/{APPLICATION_PRINCIPAL_ID}?" in url:
            return {
                "id": APPLICATION_PRINCIPAL_ID,
                "appId": APPLICATION_CLIENT_ID,
                "servicePrincipalType": "Application",
            }
        raise AssertionError(f"unexpected Graph GET {url}")

    @staticmethod
    def _assignment(assignment_id: str, principal_id: str, role_id: str) -> dict[str, str]:
        return {
            "id": assignment_id,
            "principalId": principal_id,
            "resourceId": MCP_PRINCIPAL_ID,
            "appRoleId": role_id,
        }


def delete_calls(client: FakeAzureClient) -> list[tuple[str, str]]:
    return [call for call in client.calls if call[0] == "DELETE"]


def test_cleanup_removes_only_exact_stale_objects_and_verifies_final_state() -> None:
    client = FakeAzureClient(
        stale_assignments=("stale_one", "stale_two"),
        include_unrelated_assignment=True,
    )

    result = execute_cleanup(client, contract(), attempts=2, delay_seconds=0, sleep=lambda _: None)

    assert result["receiptVersion"] == CLEANUP_RECEIPT_VERSION
    assert result["status"] == "passed"
    assert result["verifiedCommit"] == COMMIT
    assert result["staleApplicationAssignmentsBefore"] == 2
    assert result["staleApplicationAssignmentDeletesCompleted"] == 2
    assert result["staleConnectionDeleteCompleted"] is True
    assert result["finalProjectManagedIdentityQamReadCount"] == 1
    assert result["finalAgentApplicationQamReadCount"] == 0
    assert result["mutationPerformed"] is True
    assert client.stale_assignments == []
    assert client.stale_connection is False
    calls = delete_calls(client)
    assert len(calls) == 3
    assert all("unrelated_assignment" not in url for _, url in calls)


def test_cleanup_is_idempotent_when_stale_objects_are_already_absent() -> None:
    client = FakeAzureClient(stale_assignments=(), stale_connection=False)

    result = execute_cleanup(client, contract(), attempts=1, delay_seconds=0, sleep=lambda _: None)

    assert result["status"] == "passed"
    assert result["mutationPerformed"] is False
    assert result["staleConnectionPresentBefore"] is False
    assert result["staleApplicationAssignmentsBefore"] == 0
    assert delete_calls(client) == []


@pytest.mark.parametrize("active_connection", [False])
def test_cleanup_refuses_to_mutate_without_new_connection(active_connection: bool) -> None:
    client = FakeAzureClient(active_connection=active_connection)

    with pytest.raises(CleanupValidationError, match="active qam-mcp-project-identity"):
        execute_cleanup(client, contract())

    assert delete_calls(client) == []


def test_cleanup_refuses_wrong_active_connection_auth_without_mutation() -> None:
    client = FakeAzureClient(active_auth_type="AgenticIdentityToken")

    with pytest.raises(CleanupValidationError, match="exact MCP contract"):
        execute_cleanup(client, contract())

    assert delete_calls(client) == []


def test_cleanup_refuses_reused_stale_name_with_wrong_target() -> None:
    client = FakeAzureClient(stale_target="https://different.example/mcp")

    with pytest.raises(CleanupValidationError, match="exact MCP contract"):
        execute_cleanup(client, contract())

    assert delete_calls(client) == []


def test_cleanup_refuses_ambiguous_qam_read_principal_before_mutation() -> None:
    client = FakeAzureClient(unknown_qam_principal=True)

    with pytest.raises(CleanupValidationError, match="unexpected principal"):
        execute_cleanup(client, contract())

    assert delete_calls(client) == []


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("status", "failed", "not a passed content proof"),
        ("contentMarkerVerified", False, "not a passed content proof"),
        ("verifiedCommit", "b" * 40, "commit does not match"),
        ("toolEvents", ["qam.resolve_concepts"], "exact MCP acceptance sequence"),
    ],
)
def test_input_validation_rejects_unpassed_or_mismatched_smoke(
    field: str, value: object, message: str
) -> None:
    smoke = smoke_receipt()
    smoke[field] = value

    with pytest.raises(CleanupValidationError, match=message):
        validate_cleanup_inputs(smoke, access_receipt(), attached_registration(), COMMIT)


def test_input_validation_requires_distinct_identities_and_exact_connection_name() -> None:
    access = access_receipt()
    access["applicationPrincipalId"] = PROJECT_PRINCIPAL_ID
    registration = attached_registration()
    registration["applicationPrincipalId"] = PROJECT_PRINCIPAL_ID
    with pytest.raises(CleanupValidationError, match="identities are not distinct"):
        validate_cleanup_inputs(smoke_receipt(), access, registration, COMMIT)

    registration = attached_registration()
    registration["connectionName"] = STALE_CONNECTION_NAME
    with pytest.raises(CleanupValidationError, match="connectionName"):
        validate_cleanup_inputs(smoke_receipt(), access_receipt(), registration, COMMIT)
