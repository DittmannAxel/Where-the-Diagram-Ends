# QAM Microsoft Foundry Agent Application

This package publishes a Microsoft Foundry prompt agent that uses the deployed Quick Agentic
Memory Streamable HTTP MCP endpoint. It does not copy the knowledge: GitHub remains the source of
truth, Fabric remains the graph index, and the published agent receives seven bounded read-only
QAM tools.

The integration uses a published **Agent Application**, not an unpublished project agent. This is
a security boundary: legacy unpublished prompt agents can share the project's development
identity, while the published application has its own `defaultInstanceIdentity`. This flow ignores
any underlying version `instance_identity`. The application identity remains a separately audited
publishing/invocation boundary; the RemoteTool compatibility path explicitly uses the Foundry
project's system-assigned managed identity as its outbound caller.

## Identity and call chain

There are four deliberately separate identities:

1. **Outbound Foundry project managed identity** — the system-assigned identity on the exact
   project ARM resource. Its Entra `appId` and principal object ID are resolved through Microsoft
   Graph, granted only `Qam.Read`, and admitted by the exact EasyAuth client/principal allowlists.
2. **Agent Application identity** — Foundry's distinct
   `properties.defaultInstanceIdentity.clientId/principalId`. It is recorded and stability-checked
   across deployment mutations, but it is not the outbound MCP caller for
   `ProjectManagedIdentity` connections.
3. **Inbound invoker identity** — the human, CI service principal, or managed identity that calls
   the published Responses endpoint; it needs `Foundry User` at the individual Agent Application
   scope.
4. **QAM Container App runtime identity** — accesses Fabric, Key Vault, and monitoring. The
   industrial Graph Preview path currently gives it workspace Contributor as an explicitly
   recorded query compatibility workaround. It is not allowed to invoke the published application
   and is not the inbound MCP caller.

Provisioning is fail-closed and two-phase:

1. `identity` creates an inert, tool-less agent version, publishes it through the stable
   `2026-05-15-preview` Agent Application and managed deployment ARM resources, and polls the application's
   distinct `defaultInstanceIdentity`, derives the exact project system identity through ARM and
   Graph, and verifies both remain stable across the running deployment. Each provisioning poll is
   bounded to five minutes at three-second intervals. A transient `404` immediately after an
   asynchronous create is retried; authorization and all other ARM failures stop immediately.
2. An administrator runs `configure-access.sh`. The script reads the live application resource,
   verifies the application and project identity pairs against the registration artifact, grants
   `Qam.Read` only to the project managed identity, verifies the resulting assignment, and emits a
   versioned non-secret access receipt bound to the planned Container App.
3. The QAM Container App is redeployed with only the project managed identity client ID and
   principal ID in its EasyAuth allowlists. `allowedPrincipals` contains only `identities`; adding
   even an empty `groups` member enables a different EasyAuth authorization path and is rejected.
4. `attach` requires that receipt and, before each connection/version/deployment mutation,
   rechecks the live identity, `Qam.Read` assignment, MCP API assignment-required setting,
   Container App ingress, and exact EasyAuth audience/client/principal policy. Only then does it
   create the secretless `ProjectManagedIdentity` RemoteTool connection, create the MCP-enabled agent
   version, and update the published deployment to that immutable version.
5. `qam-foundry-smoke` calls only the published Agent Application endpoint and verifies actual MCP
   events, commit propagation, provenance, and content.

The tool-less first deployment prevents the project identity from making a downstream QAM call
before its exact identity is derived and an administrator grants it access. Neither the project nor
the application can grant itself access.

## Prerequisites

- Python 3.11 or later and [uv](https://docs.astral.sh/uv/).
- A Microsoft Foundry project and deployed tool-capable model.
- `Foundry Project Manager` on the Foundry resource to publish the prompt agent.
- Permission to create the project RemoteTool connection.
- An Entra/Azure administrator permitted to assign the QAM application role and Azure RBAC roles.
- The deterministic planned QAM Container App URL/resource ID and the MCP API application client
  ID. The app itself need not exist for `identity` or `configure-access`, but it must be deployed
  and healthy before `attach`.
- The immutable image digest, Fabric IDs, and GitHub configuration required by
  [`../../scripts/deploy.sh`](../../scripts/deploy.sh).

Install exactly the lock file:

```bash
cd quickagenticmemory/agents/foundry
uv sync --locked --all-groups
```

Set non-secret values in the shell; never commit a populated `.env` file:

```bash
export FOUNDRY_PROJECT_ENDPOINT='https://<account>.services.ai.azure.com/api/projects/<project>'
export FOUNDRY_PROJECT_RESOURCE_ID='/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>'
export FOUNDRY_MODEL_DEPLOYMENT_NAME='<model-deployment>'
export QAM_FOUNDRY_AGENT_NAME='qam-knowledge-agent'
export QAM_FOUNDRY_APPLICATION_NAME='qam-knowledge-application'
export QAM_FOUNDRY_DEPLOYMENT_NAME='qam-managed-deployment'
export QAM_FOUNDRY_CONNECTION_NAME='qam-mcp-project-identity'
export QAM_MCP_URL='https://<qam-app-host>/mcp'
export QAM_ALLOWED_MCP_HOST='<qam-app-host>'
export QAM_MCP_API_CLIENT_ID='<mcp-api-application-client-id>'
export QAM_MCP_AUDIENCE="api://${QAM_MCP_API_CLIENT_ID}"
export QAM_CONTAINER_APP_RESOURCE_ID='/subscriptions/<subscription>/resourceGroups/<rg>/providers/Microsoft.App/containerApps/<planned-app-name>'
```

Before mutation, validation couples the endpoint account/project to the ARM resource ID
case-insensitively. It also pins the MCP URL to HTTPS, the exact allowed host, and `/mcp`, with no
credentials, query, or fragment.

## Phase 1: publish the distinct application identity

Prepare the final MCP audience before publishing the tool-less application. This creates no caller assignment:

```bash
../../scripts/bootstrap-mcp-entra.sh \
  --display-name 'Quick Agentic Memory MCP' \
  --prepare-only \
  > ../../.artifacts/mcp-api.json

export QAM_MCP_API_CLIENT_ID="$(jq -r '.mcpApiClientId' ../../.artifacts/mcp-api.json)"
export QAM_MCP_AUDIENCE="$(jq -r '.mcpApiAudience' ../../.artifacts/mcp-api.json)"
```

```bash
uv run qam-foundry-register identity \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT" \
  --project-resource-id "$FOUNDRY_PROJECT_RESOURCE_ID" \
  --model "$FOUNDRY_MODEL_DEPLOYMENT_NAME" \
  --agent-name "$QAM_FOUNDRY_AGENT_NAME" \
  --application-name "$QAM_FOUNDRY_APPLICATION_NAME" \
  --deployment-name "$QAM_FOUNDRY_DEPLOYMENT_NAME" \
  --mcp-url "$QAM_MCP_URL" \
  --mcp-audience "$QAM_MCP_AUDIENCE" \
  --allowed-mcp-host "$QAM_ALLOWED_MCP_HOST" \
  --output ../../.artifacts/foundry-published-identity.json
```

The artifact contains identifiers, never credentials. It records the application resource ID and
its distinct client/principal pair, the separately derived project managed-identity pair, explicit
identity source/caller fields, and the exact downstream access contract. The `.artifacts`
directory is ignored. Use `--dry-run` to inspect the inert agent, application, and deployment
payloads without creating Azure resources. `identity` accepts the deterministic planned MCP URL
before the Container App exists: it validates the URL contract but performs no DNS or HTTP probe
and creates no RemoteTool connection.

## Phase 2: grant outbound QAM access and redeploy EasyAuth

This is an explicit privileged action:

```bash
./configure-access.sh \
  --registration ../../.artifacts/foundry-published-identity.json \
  --mcp-api-client-id "$QAM_MCP_API_CLIENT_ID" \
  --container-app-resource-id "$QAM_CONTAINER_APP_RESOURCE_ID" \
  > ../../.artifacts/foundry-access.json
```

The Container App ID is deterministic and may be supplied before the app exists; it must name the
same planned app that will serve `QAM_MCP_URL`. The wrapper refuses an unpublished/shared identity,
a mismatched audience, a mismatched allowlist, either identity pair differing from live ARM/Graph,
or any overlap between the application and project identity dimensions. It then invokes the shared
`bootstrap-mcp-entra.sh`, preserves the existing Graph `api` configuration while enforcing
`requestedAccessTokenVersion: 2`, and verifies the exact enabled
Application `Qam.Read` app role, assignment-required MCP service principal, and concrete role
assignment, and records their IDs in the receipt. It creates no client secret or certificate.

Export both returned allowlists:

```bash
export QAM_ALLOWED_CLIENT_APPLICATION_IDS="$(jq -r '.allowedClientApplicationIds | join(",")' ../../.artifacts/foundry-access.json)"
export QAM_ALLOWED_PRINCIPAL_IDS="$(jq -r '.allowedPrincipalIds | join(",")' ../../.artifacts/foundry-access.json)"
```

Run `../../scripts/what-if.sh` and then `../../scripts/deploy.sh` with all normal QAM inputs plus:

```text
--mcp-api-client-id "$QAM_MCP_API_CLIENT_ID"
--allowed-client-application-ids "$QAM_ALLOWED_CLIENT_APPLICATION_IDS"
--allowed-principal-ids "$QAM_ALLOWED_PRINCIPAL_IDS"
```

EasyAuth checks audience, token application ID, and token object ID for the project identity. Its
`allowedPrincipals` object has exactly one key, `identities`; group authorization is not enabled.
The MCP API independently requires `Qam.Read` in the v2 access token.

## Phase 3: authorize an inbound smoke-test caller

Do not confuse the invoking operator with the outbound application identity. Give the operator,
CI service principal, or managed identity `Foundry User` only at this application scope:

```bash
./configure-invoker.sh \
  --registration ../../.artifacts/foundry-published-identity.json \
  --invoker-principal-id '<operator-or-service-principal-object-id>' \
  --invoker-principal-type ServicePrincipal \
  > ../../.artifacts/foundry-invoker.json
```

Use `--invoker-principal-type User` for a human object ID or `Group` for an Entra group. The script
uses the immutable Foundry User role-definition ID and reconciles the assignment idempotently at
the exact Agent Application resource. It does not give the invoker `Qam.Read` and does not change
the application's outbound identity.

## Phase 4: attach and deploy the MCP-enabled version

After the new QAM Container App revision is healthy:

```bash
uv run qam-foundry-register attach \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT" \
  --project-resource-id "$FOUNDRY_PROJECT_RESOURCE_ID" \
  --model "$FOUNDRY_MODEL_DEPLOYMENT_NAME" \
  --agent-name "$QAM_FOUNDRY_AGENT_NAME" \
  --application-name "$QAM_FOUNDRY_APPLICATION_NAME" \
  --deployment-name "$QAM_FOUNDRY_DEPLOYMENT_NAME" \
  --mcp-url "$QAM_MCP_URL" \
  --mcp-audience "$QAM_MCP_AUDIENCE" \
  --allowed-mcp-host "$QAM_ALLOWED_MCP_HOST" \
  --registration ../../.artifacts/foundry-published-identity.json \
  --access-receipt ../../.artifacts/foundry-access.json \
  --output ../../.artifacts/foundry-attached.json
```

Before each connection, agent-version, or deployment mutation, the command re-reads Microsoft
Graph and ARM. The live MCP API
application must still expose exactly one enabled `Qam.Read` role for `Application` members, and
its ID must match the receipt. Its service principal must still require assignments; the receipt's
concrete app-role assignment must bind the Foundry project's managed-identity principal to that
exact role and MCP API principal. The distinct Agent Application identity and project identity must
both still match ARM/Graph. The
live Container App must serve the configured host, and `authConfigs/current` must have HTTPS and
platform auth enabled, expose only `/healthz` anonymously, return `401` otherwise, and contain
exactly the configured API client, audience, one allowed project client ID, and an
`allowedPrincipals` object containing only one allowed project principal ID. Missing read
permission, an extra `groups` member (including `groups: []`), or any mismatch fails closed. The
attach operator therefore
needs ARM read access to the Container App/auth config and Microsoft Graph permission to read the
MCP application registration, both service principals, and app-role assignment, in addition to its
Foundry mutation permissions.

The command then performs credential-free, no-redirect boundary checks: `GET /healthz` must return
exactly `200` with `{"status":"ok"}`, and anonymous `GET /mcp` must return exactly `401`. Neither
request carries an Azure token, model key, or GitHub credential.

The exact MCP allowlist is:

- `browse_index`
- `resolve_concepts`
- `get_neighbors`
- `get_backlinks`
- `find_path`
- `read_concepts`
- `trace_provenance`

`propose_wiki_update` and unknown future tools are excluded. Approval is `never` only for these
read operations. The persisted create-version response must echo exactly this one MCP tool,
connection, URL, allowlist, and approval contract before the deployment is mutated. The deployment
is then updated to the new immutable version and must reach `Succeeded`/`Running`; the application
identity must remain unchanged.

## Live acceptance smoke

Use a full immutable commit present in the graph and a literal marker from the target Markdown:

```bash
uv run qam-foundry-smoke \
  --project-endpoint "$FOUNDRY_PROJECT_ENDPOINT" \
  --application-name "$QAM_FOUNDRY_APPLICATION_NAME" \
  --registration ../../.artifacts/foundry-attached.json \
  --expected-commit '<full-lowercase-git-sha>' \
  --concept-term 'Wiki MCP Gateway' \
  --expected-content 'commit-pinned'
```

The attached-phase artifact binds the test to the exact application endpoint and seven-tool
allowlist. The smoke client authenticates with `DefaultAzureCredential` to the stateless published
endpoint:

```text
.../applications/<application>/protocols/openai/responses?api-version=2025-11-15-preview
```

Success requires exactly four completed, nonparallel events in order:

```text
qam.resolve_concepts
qam.get_neighbors
qam.trace_provenance
qam.read_concepts
```

The first resolved concept ID must flow through traversal, provenance, and reading. Every result
must prove the expected commit, `read_concepts` must receive that full SHA explicitly, and the
document must contain the marker. The request sets `max_tool_calls=4`, `parallel_tool_calls=false`,
and `store=false`. Output contains evidence metadata but no document body. Approval requests,
unexpected tools/servers, MCP errors, missing evidence, HTTP redirects, and cloud errors all exit
nonzero. The success summary emits the verified commit and a marker boolean, never the literal
marker or document body.

## Security boundaries

- No model key, GitHub token, MCP bearer token, client secret, or certificate is stored. Local
  management and smoke commands use `DefaultAzureCredential`; Foundry obtains the outbound MCP
  token for the Foundry project managed identity and exact audience.
- The RemoteTool connection is a project resource and deliberately uses that project's
  system-assigned identity. This means other agents in the same project share the outbound identity;
  the seven-tool MCP allowlist and project-level `Qam.Read`/EasyAuth gate are the isolation boundary.
  The separately recorded Agent Application identity is not granted downstream access.
- Foundry never receives GitHub credentials. The QAM server uses its separately configured GitHub
  App installation credential from Key Vault and enforces repository/ref/path bounds.
- Fabric is accessed by the QAM runtime identity, not by the Foundry agent. The agent receives only
  bounded graph/read results through MCP. The runtime's current workspace Contributor workaround
  is write-capable even though the MCP surface is not; reassess it against documented Viewer query
  support after Preview changes.
- GitHub Markdown and graph fields are untrusted input. Agent instructions never treat them as
  instructions, but content review, evaluation, rate limits, and audit monitoring remain required.
- The application endpoint supports stateless Responses calls in this flow. Clients must not
  assume stored or end-user-isolated conversations.
- Microsoft currently labels Agent Applications as its legacy publishing experience. This PoC
  uses the tenant-registered `2026-05-15-preview` management resources because they expose the
  distinct, auditable application identity required by this gate; reassess the documented
  migration path before treating the design as production.
- Provisioning, RBAC/app-role changes, redeployment, and model calls mutate the tenant. Unit tests
  and CI perform no Azure mutation.

## Local verification

Run from `quickagenticmemory/agents/foundry/`:

```bash
uv sync --locked --all-groups
uv run --frozen pytest
uv run --frozen ruff check .
uv run --frozen ruff format --check .
bash -n configure-access.sh configure-invoker.sh
shellcheck -x configure-access.sh configure-invoker.sh
```

Offline tests use fake Foundry, Graph, ARM, and Responses transports. They cover endpoint/resource
coupling, stable application/deployment payloads, ARM/Graph project-identity binding,
published-identity and v2 access-receipt binding, fail-before-mutation role/EasyAuth checks,
rejection of group authorization and mismatched identity shapes, redirect
and token redaction, the persisted read-only allowlist, four-call bounds, event order,
provenance/commit propagation, and content proof. No live smoke runs in CI.

## Microsoft references

- [Agent identity concepts](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity)
- [Publish an agent as an Agent Application](https://learn.microsoft.com/azure/foundry/agents/how-to/agent-applications)
- [Migrate from Agent Applications](https://learn.microsoft.com/azure/foundry/agents/how-to/migrate-agent-applications)
- [Agent Application ARM 2026-05-15-preview](https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/2026-05-15-preview/accounts/projects/applications)
- [Agent deployment ARM 2026-05-15-preview](https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/2026-05-15-preview/accounts/projects/applications/agentdeployments)
- [MCP authentication](https://learn.microsoft.com/azure/foundry/agents/how-to/mcp-authentication)
- [MCP tools](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol)
- [Foundry authentication and role IDs](https://learn.microsoft.com/azure/foundry/concepts/authentication-authorization-foundry)
- [Azure AI Projects Python SDK](https://learn.microsoft.com/python/api/overview/azure/ai-projects-readme)
