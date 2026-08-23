from __future__ import annotations

import pytest

from qam_foundry.http import AzureRequestError
from qam_foundry.register import (
    _access_receipt_contract,
    _application_identity,
    _registration_identity,
    _verify_live_access,
    _verify_mcp_boundary,
    _wait_for_application,
    _wait_for_deployment,
    attach_mcp,
    create_published_identity,
)

from .test_contracts import valid_config

CLIENT_ID = "623e4567-e89b-42d3-a456-426614174000"
PRINCIPAL_ID = "223e4567-e89b-42d3-a456-426614174000"
MCP_CLIENT_ID = "123e4567-e89b-42d3-a456-426614174000"
MCP_APP_OBJECT_ID = "823e4567-e89b-42d3-a456-426614174000"
MCP_PRINCIPAL_ID = "323e4567-e89b-42d3-a456-426614174000"
QAM_ROLE_ID = "423e4567-e89b-42d3-a456-426614174000"
QAM_ASSIGNMENT_ID = "UxOIjjUXr0WvIe4TRFgqTY4z9Wu5KxpBtlEpoTGjw-A"
CONTAINER_APP_ID = (
    "/subscriptions/123e4567-e89b-42d3-a456-426614174000/resourceGroups/qam-rg/"
    "providers/Microsoft.App/containerApps/qam-green"
)


def application_payload() -> dict[str, object]:
    return {
        "properties": {
            "provisioningState": "Succeeded",
            "agents": [{"agentName": "qam-knowledge-agent", "agentId": "agent-guid"}],
            "authorizationPolicy": {"authorizationScheme": "Default"},
            "defaultInstanceIdentity": {
                "kind": "AgentInstance",
                "clientId": CLIENT_ID,
                "principalId": PRINCIPAL_ID,
                "type": "System",
            },
        }
    }


def registration() -> dict[str, object]:
    config = valid_config()
    return {
        "phase": "published-identity",
        "agentName": config.agent_name,
        "applicationName": config.application_name,
        "applicationResourceId": config.application_resource_id,
        "applicationOpenAIBaseUrl": config.application_openai_base_url,
        "projectResourceId": config.project_resource_id,
        "deploymentName": config.deployment_name,
        "connectionName": config.connection_name,
        "applicationClientId": CLIENT_ID,
        "applicationPrincipalId": PRINCIPAL_ID,
        "mcpAudience": config.mcp_audience,
        "accessContract": {
            "identitySource": "AgentApplication.defaultInstanceIdentity",
            "allowedClientApplicationIds": [CLIENT_ID],
            "allowedPrincipalIds": [PRINCIPAL_ID],
            "requiredAppRole": "Qam.Read",
        },
    }


def access_receipt() -> dict[str, object]:
    config = valid_config()
    return {
        "receiptVersion": "qam-foundry-access/1.0",
        "phase": "access-configured",
        "agentName": config.agent_name,
        "applicationName": config.application_name,
        "applicationResourceId": config.application_resource_id,
        "projectResourceId": config.project_resource_id,
        "applicationClientId": CLIENT_ID,
        "applicationPrincipalId": PRINCIPAL_ID,
        "mcpUrl": config.mcp_url,
        "mcpApiClientId": MCP_CLIENT_ID,
        "mcpApiApplicationObjectId": MCP_APP_OBJECT_ID,
        "mcpApiPrincipalId": MCP_PRINCIPAL_ID,
        "mcpApiAudience": config.mcp_audience,
        "qamReadAppRoleId": QAM_ROLE_ID,
        "qamReadAssignmentId": QAM_ASSIGNMENT_ID,
        "containerAppResourceId": CONTAINER_APP_ID,
        "requiredAppRole": "Qam.Read",
        "allowedClientApplicationIds": [CLIENT_ID],
        "allowedPrincipalIds": [PRINCIPAL_ID],
    }


def auth_config_payload() -> dict[str, object]:
    return {
        "properties": {
            "globalValidation": {
                "excludedPaths": ["/healthz"],
                "unauthenticatedClientAction": "Return401",
            },
            "httpSettings": {"requireHttps": True},
            "identityProviders": {
                "azureActiveDirectory": {
                    "enabled": True,
                    "registration": {"clientId": MCP_CLIENT_ID},
                    "validation": {
                        "allowedAudiences": [f"api://{MCP_CLIENT_ID}"],
                        "defaultAuthorizationPolicy": {
                            "allowedApplications": [CLIENT_ID],
                            "allowedPrincipals": {
                                "groups": [],
                                "identities": [PRINCIPAL_ID],
                            },
                        },
                    },
                }
            },
            "platform": {"enabled": True},
        }
    }


def test_identity_accepts_only_published_application_shape() -> None:
    assert _application_identity(application_payload()) == (CLIENT_ID, PRINCIPAL_ID)
    shared_project_shape = {"instance_identity": {"client_id": CLIENT_ID, "principal_id": PRINCIPAL_ID}}
    assert _application_identity(shared_project_shape) is None
    wrong_kind = application_payload()
    wrong_kind["properties"]["defaultInstanceIdentity"]["kind"] = "Managed"  # type: ignore[index]
    assert _application_identity(wrong_kind) is None


def test_attach_registration_binds_application_project_and_both_identity_dimensions() -> None:
    assert _registration_identity(registration(), valid_config()) == (CLIENT_ID, PRINCIPAL_ID)
    bad = registration()
    bad["accessContract"] = {
        "identitySource": "AgentApplication.defaultInstanceIdentity",
        "allowedClientApplicationIds": [CLIENT_ID],
        "allowedPrincipalIds": ["different"],
        "requiredAppRole": "Qam.Read",
    }
    with pytest.raises(ValueError, match="principal allowlist"):
        _registration_identity(bad, valid_config())

    wrong_project = registration()
    wrong_project["projectResourceId"] = str(wrong_project["projectResourceId"]).replace(
        "/projects/qam", "/projects/other"
    )
    with pytest.raises(ValueError, match="project resource ID"):
        _registration_identity(wrong_project, valid_config())


def test_attach_rejects_old_shared_identity_phase_or_audience() -> None:
    wrong_phase = registration()
    wrong_phase["phase"] = "identity"
    with pytest.raises(ValueError, match="published-identity"):
        _registration_identity(wrong_phase, valid_config())
    wrong_audience = registration()
    wrong_audience["mcpAudience"] = "api://323e4567-e89b-42d3-a456-426614174000"
    with pytest.raises(ValueError, match="mcpAudience"):
        _registration_identity(wrong_audience, valid_config())


def test_access_receipt_binds_registration_role_and_container_app() -> None:
    access = _access_receipt_contract(access_receipt(), registration(), valid_config())
    assert access["qamReadAppRoleId"] == QAM_ROLE_ID
    assert access["qamReadAssignmentId"] == QAM_ASSIGNMENT_ID
    assert access["containerAppResourceId"] == CONTAINER_APP_ID

    wrong = access_receipt()
    wrong["applicationPrincipalId"] = MCP_PRINCIPAL_ID
    with pytest.raises(ValueError, match="applicationPrincipalId"):
        _access_receipt_contract(wrong, registration(), valid_config())

    wrong_container = access_receipt()
    wrong_container["containerAppResourceId"] = "/subscriptions/../../other"
    with pytest.raises(ValueError, match="Container App resource ID"):
        _access_receipt_contract(wrong_container, registration(), valid_config())

    unsafe_assignment = access_receipt()
    unsafe_assignment["qamReadAssignmentId"] = "../../appRoleAssignments/other"
    with pytest.raises(ValueError, match="Microsoft Graph object key"):
        _access_receipt_contract(unsafe_assignment, registration(), valid_config())


class FakeAgents:
    def __init__(self):
        self.created_definitions: list[dict[str, object]] = []

    def create_version(self, *, agent_name, definition, description, metadata):
        assert agent_name == "qam-knowledge-agent"
        self.created_definitions.append(definition.as_dict())
        return type(
            "Created",
            (),
            {"version": str(len(self.created_definitions)), "definition": definition},
        )()

    def get(self, *, agent_name):
        assert agent_name == "qam-knowledge-agent"
        return type("Agent", (), {"id": "agent-guid"})()


class FakeProject:
    agents = FakeAgents()

    def __init__(self, *, endpoint, credential):
        assert endpoint.endswith("/api/projects/qam")

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None


class FakeArm:
    def __init__(
        self,
        *,
        auth_config: dict[str, object] | None = None,
        qam_role_value: str = "Qam.Read",
        assignment_role_id: str = QAM_ROLE_ID,
        drift_after_graph_reads: int | None = None,
    ):
        self.calls: list[tuple[tuple[object, ...], dict[str, object]]] = []
        self.deployed_version = "1"
        self.auth_config = auth_config or auth_config_payload()
        self.qam_role_value = qam_role_value
        self.assignment_role_id = assignment_role_id
        self.drift_after_graph_reads = drift_after_graph_reads
        self.graph_app_reads = 0

    def request(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        method, url = args[:2]
        if method == "PUT" and "/agentdeployments/" in url:
            body = kwargs["body"]
            self.deployed_version = body["properties"]["agents"][0]["agentVersion"]
            return {"ok": True}
        if method == "GET" and "/agentdeployments/" in url:
            return {
                "properties": {
                    "provisioningState": "Succeeded",
                    "state": "Running",
                    "agents": [
                        {
                            "agentName": "qam-knowledge-agent",
                            "agentVersion": self.deployed_version,
                        }
                    ],
                }
            }
        if method == "GET" and url.startswith("https://management.azure.com") and "/applications/" in url:
            return application_payload()
        if method == "GET" and url.startswith(
            f"https://graph.microsoft.com/v1.0/applications/{MCP_APP_OBJECT_ID}?"
        ):
            self.graph_app_reads += 1
            role_value = (
                "Different.Role"
                if self.drift_after_graph_reads is not None
                and self.graph_app_reads > self.drift_after_graph_reads
                else self.qam_role_value
            )
            return {
                "id": MCP_APP_OBJECT_ID,
                "appId": MCP_CLIENT_ID,
                "appRoles": [
                    {
                        "id": QAM_ROLE_ID,
                        "value": role_value,
                        "isEnabled": True,
                        "allowedMemberTypes": ["Application"],
                    }
                ],
            }
        if method == "GET" and url.startswith("https://graph.microsoft.com/v1.0/servicePrincipals/"):
            if f"/{PRINCIPAL_ID}/appRoleAssignments/{QAM_ASSIGNMENT_ID}" in url:
                return {
                    "id": QAM_ASSIGNMENT_ID,
                    "appRoleId": self.assignment_role_id,
                    "principalId": PRINCIPAL_ID,
                    "resourceId": MCP_PRINCIPAL_ID,
                }
            if f"/{MCP_PRINCIPAL_ID}?" in url:
                return {
                    "id": MCP_PRINCIPAL_ID,
                    "appId": MCP_CLIENT_ID,
                    "appRoleAssignmentRequired": True,
                }
            if f"/{PRINCIPAL_ID}?" in url:
                return {"id": PRINCIPAL_ID, "appId": CLIENT_ID}
        if method == "GET" and "/authConfigs/current" in url:
            return self.auth_config
        if method == "GET" and url.startswith(f"https://management.azure.com{CONTAINER_APP_ID}?"):
            return {
                "properties": {
                    "configuration": {
                        "ingress": {
                            "external": True,
                            "fqdn": "qam.green.azurecontainerapps.io",
                        }
                    }
                }
            }
        return {"ok": True}


class EventuallyConsistentArm(FakeArm):
    def __init__(self, *, resource: str, status_code: int = 404):
        super().__init__()
        self.resource = resource
        self.status_code = status_code
        self.failed = False

    def request(self, *args, **kwargs):
        method, url = args[:2]
        if method == "GET" and self.resource in url and not self.failed:
            self.failed = True
            raise AzureRequestError("redacted transient ARM response", status_code=self.status_code)
        return super().request(*args, **kwargs)


class FakeBoundaryResponse:
    def __init__(self, status_code: int, body: object | None = None):
        self.status_code = status_code
        self.body = {"status": "ok"} if body is None else body
        self.closed = False

    def json(self):
        return self.body

    def close(self):
        self.closed = True


class FakeBoundarySession:
    def __init__(self, statuses: tuple[int, int] = (200, 401)):
        self.responses = [FakeBoundaryResponse(status) for status in statuses]
        self.calls: list[tuple[tuple[object, ...], dict[str, object]]] = []

    def request(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        return self.responses[len(self.calls) - 1]


def test_attach_preflight_probes_no_credentials_and_refuses_redirects() -> None:
    session = FakeBoundarySession()
    _verify_mcp_boundary(valid_config(), session)  # type: ignore[arg-type]
    assert [call[0][1] for call in session.calls] == [
        "https://qam.green.azurecontainerapps.io/healthz",
        "https://qam.green.azurecontainerapps.io/mcp",
    ]
    for _, kwargs in session.calls:
        assert kwargs["headers"] == {"Accept": "application/json"}
        assert kwargs["allow_redirects"] is False
    assert all(response.closed for response in session.responses)

    with pytest.raises(RuntimeError, match="expected HTTP 200"):
        _verify_mcp_boundary(  # type: ignore[arg-type]
            valid_config(), FakeBoundarySession(statuses=(302, 401))
        )
    wrong_health = FakeBoundarySession()
    wrong_health.responses[0].body = {"status": "different"}
    with pytest.raises(RuntimeError, match="unexpected contract"):
        _verify_mcp_boundary(valid_config(), wrong_health)  # type: ignore[arg-type]


def test_provisioning_polls_through_only_transient_arm_not_found() -> None:
    config = valid_config()
    application_arm = EventuallyConsistentArm(resource="/applications/")
    assert _application_identity(
        _wait_for_application(
            application_arm,  # type: ignore[arg-type]
            config,
            timeout_seconds=1,
            poll_interval_seconds=0,
        )
    ) == (CLIENT_ID, PRINCIPAL_ID)
    deployment_arm = EventuallyConsistentArm(resource="/agentdeployments/")
    result = _wait_for_deployment(
        deployment_arm,  # type: ignore[arg-type]
        config,
        "1",
        timeout_seconds=1,
        poll_interval_seconds=0,
    )
    assert result["properties"]["state"] == "Running"  # type: ignore[index]

    forbidden_arm = EventuallyConsistentArm(resource="/applications/", status_code=403)
    with pytest.raises(AzureRequestError) as caught:
        _wait_for_application(
            forbidden_arm,  # type: ignore[arg-type]
            config,
            timeout_seconds=1,
            poll_interval_seconds=0,
        )
    assert caught.value.status_code == 403


def test_zero_timeout_live_recheck_does_not_hide_not_found() -> None:
    arm = EventuallyConsistentArm(resource="/applications/")
    with pytest.raises(AzureRequestError) as caught:
        _wait_for_application(arm, valid_config(), timeout_seconds=0)  # type: ignore[arg-type]
    assert caught.value.status_code == 404


def test_live_access_requires_exact_qam_read_assignment_before_mutation() -> None:
    config = valid_config()
    arm = FakeArm(assignment_role_id="723e4567-e89b-42d3-a456-426614174000")
    access = _access_receipt_contract(access_receipt(), registration(), config)

    with pytest.raises(ValueError, match="Qam.Read app-role assignment"):
        _verify_live_access(  # type: ignore[arg-type]
            config, (CLIENT_ID, PRINCIPAL_ID), access, arm
        )
    assert not any(call[0][0] == "PUT" for call in arm.calls)


def test_live_access_rejects_receipt_role_id_when_app_role_is_not_qam_read() -> None:
    config = valid_config()
    arm = FakeArm(qam_role_value="Different.Role")
    access = _access_receipt_contract(access_receipt(), registration(), config)

    with pytest.raises(ValueError, match="exact Qam.Read role"):
        _verify_live_access(  # type: ignore[arg-type]
            config, (CLIENT_ID, PRINCIPAL_ID), access, arm
        )
    assert not any(call[0][0] == "PUT" for call in arm.calls)


@pytest.mark.parametrize(
    ("field", "replacement"),
    [
        ("audience", ["api://723e4567-e89b-42d3-a456-426614174000"]),
        ("client", "723e4567-e89b-42d3-a456-426614174000"),
        ("applications", [CLIENT_ID, "723e4567-e89b-42d3-a456-426614174000"]),
        ("principals", ["723e4567-e89b-42d3-a456-426614174000"]),
    ],
)
def test_live_access_requires_exact_easyauth_boundary_before_mutation(
    field: str, replacement: object
) -> None:
    auth = auth_config_payload()
    aad = auth["properties"]["identityProviders"]["azureActiveDirectory"]  # type: ignore[index]
    if field == "audience":
        aad["validation"]["allowedAudiences"] = replacement  # type: ignore[index]
    elif field == "client":
        aad["registration"]["clientId"] = replacement  # type: ignore[index]
    elif field == "applications":
        aad["validation"]["defaultAuthorizationPolicy"]["allowedApplications"] = replacement  # type: ignore[index]
    else:
        aad["validation"]["defaultAuthorizationPolicy"]["allowedPrincipals"][  # type: ignore[index]
            "identities"
        ] = replacement
    arm = FakeArm(auth_config=auth)
    access = _access_receipt_contract(access_receipt(), registration(), valid_config())

    with pytest.raises(ValueError, match="authConfig does not exactly enforce"):
        _verify_live_access(  # type: ignore[arg-type]
            valid_config(), (CLIENT_ID, PRINCIPAL_ID), access, arm
        )
    assert not any(call[0][0] == "PUT" for call in arm.calls)


def test_attach_fails_before_connection_or_version_mutation_when_access_drifted(monkeypatch) -> None:
    import azure.ai.projects

    FakeProject.agents = FakeAgents()
    monkeypatch.setattr(azure.ai.projects, "AIProjectClient", FakeProject)
    auth = auth_config_payload()
    auth["properties"]["platform"]["enabled"] = False  # type: ignore[index]
    arm = FakeArm(auth_config=auth)

    with pytest.raises(ValueError, match="authConfig does not exactly enforce"):
        attach_mcp(  # type: ignore[arg-type]
            valid_config(),
            object(),
            arm,
            registration(),
            access_receipt(),
            FakeBoundarySession(),
        )
    assert FakeProject.agents.created_definitions == []
    assert not any(call[0][0] == "PUT" for call in arm.calls)


def test_attach_rechecks_receipt_gate_between_connection_and_version_mutations(monkeypatch) -> None:
    import azure.ai.projects

    FakeProject.agents = FakeAgents()
    monkeypatch.setattr(azure.ai.projects, "AIProjectClient", FakeProject)
    arm = FakeArm(drift_after_graph_reads=1)

    with pytest.raises(ValueError, match="exact Qam.Read role"):
        attach_mcp(  # type: ignore[arg-type]
            valid_config(),
            object(),
            arm,
            registration(),
            access_receipt(),
            FakeBoundarySession(),
        )
    connection_puts = [call for call in arm.calls if call[0][0] == "PUT" and "/connections/" in call[0][1]]
    deployment_puts = [
        call for call in arm.calls if call[0][0] == "PUT" and "/agentdeployments/" in call[0][1]
    ]
    assert len(connection_puts) == 1
    assert FakeProject.agents.created_definitions == []
    assert deployment_puts == []


def test_two_phase_publishes_distinct_identity_then_updates_deployment(monkeypatch) -> None:
    import azure.ai.projects

    FakeProject.agents = FakeAgents()
    monkeypatch.setattr(azure.ai.projects, "AIProjectClient", FakeProject)
    config = valid_config()
    arm = FakeArm()

    identity_result = create_published_identity(config, object(), arm)  # type: ignore[arg-type]
    assert identity_result["phase"] == "published-identity"
    assert identity_result["applicationClientId"] == CLIENT_ID
    assert identity_result["applicationPrincipalId"] == PRINCIPAL_ID
    assert identity_result["accessContract"]["identitySource"] == (  # type: ignore[index]
        "AgentApplication.defaultInstanceIdentity"
    )
    assert FakeProject.agents.created_definitions[0]["tools"] == []
    app_put = next(call for call in arm.calls if call[0][0] == "PUT" and "/applications/" in call[0][1])
    assert "api-version=2026-05-15-preview" in app_put[0][1]

    attached = attach_mcp(  # type: ignore[arg-type]
        config, object(), arm, registration(), access_receipt(), FakeBoundarySession()
    )
    assert attached["phase"] == "attached"
    assert attached["accessReceiptVersion"] == "qam-foundry-access/1.0"
    graph_application_reads = [
        call
        for call in arm.calls
        if call[0][0] == "GET"
        and str(call[0][1]).startswith(f"https://graph.microsoft.com/v1.0/applications/{MCP_APP_OBJECT_ID}?")
    ]
    assert len(graph_application_reads) == 3
    assert FakeProject.agents.created_definitions[1]["tools"][0]["allowed_tools"]  # type: ignore[index]
    assert FakeProject.agents.created_definitions[1]["tools"][0]["require_approval"] == "never"  # type: ignore[index]
    connection_put = next(call for call in arm.calls if call[0][0] == "PUT" and "/connections/" in call[0][1])
    assert connection_put[1]["body"]["properties"]["authType"] == "AgenticIdentityToken"  # type: ignore[index]
    deployment_puts = [
        call for call in arm.calls if call[0][0] == "PUT" and "/agentdeployments/" in call[0][1]
    ]
    assert deployment_puts[-1][1]["body"]["properties"]["agents"][0]["agentVersion"] == "2"  # type: ignore[index]
