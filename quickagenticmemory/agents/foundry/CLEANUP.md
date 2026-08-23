# Project Managed Identity migration cleanup

`qam-foundry-cleanup` is the final, fail-closed step of the migration from the published Agent
Application identity to the Foundry project's system-assigned managed identity. Run it only after
the Project Managed Identity path has passed the complete `qam-foundry-smoke` acceptance proof.

The command deletes only:

- `Qam.Read` app-role assignments whose principal, resource, and role exactly identify the distinct
  Agent Application identity, the receipt's MCP API service principal, and the receipt's `Qam.Read`
  role; and
- the exact project connection named `qam-mcp-agent-identity`, provided it is still the same
  credential-free RemoteTool connection for the receipt's MCP URL and audience.

It never deletes the Agent Application, the Foundry project, the MCP API, another app role, another
principal's assignment, or any differently named or repurposed connection.

## Required evidence

Supply all four inputs:

1. A passed `qam-foundry-smoke` JSON result. It must prove the exact four-call MCP sequence, content
   marker, application name, and immutable commit.
2. A `qam-foundry-access/2.0` `access-configured` receipt for `ProjectManagedIdentity`.
3. The matching `attached` registration result. Its connection name must be
   `qam-mcp-project-identity` and its access receipt version must be `qam-foundry-access/2.0`.
4. The expected full lowercase commit SHA. The command refuses a smoke result for any other commit.

The three JSON files are cross-bound by resource names, resource IDs, both distinct identities, MCP
API and role IDs, URL, audience, agent version, allowlist, and connection name. Their canonical
SHA-256 digests are recorded in the cleanup receipt.

## Live safety gates

Before its first `DELETE`, the command verifies all of the following live:

- the Agent Application identity and the exact running attached agent deployment;
- the Foundry project's system-assigned managed identity and both matching Entra service principals;
- access-token version 2, the single enabled Application `Qam.Read` role, and
  `appRoleAssignmentRequired=true` on the exact MCP API;
- exactly one Project Managed Identity `Qam.Read` assignment, matching the access receipt;
- no unexpected principal with that MCP API role;
- `qam-mcp-project-identity` exists and is a credential-free `ProjectManagedIdentity` RemoteTool
  connection for the exact MCP URL and audience; and
- if `qam-mcp-agent-identity` exists, it has not been reused for another endpoint or audience.

Any missing, malformed, paginated-ambiguously, inconsistent, or unexpected state stops the command
before mutation. Microsoft Graph continuation URLs are accepted only from the HTTPS
`graph.microsoft.com/v1.0` boundary.

## Run

From `quickagenticmemory/agents/foundry`, after installing the locked environment:

```bash
uv run qam-foundry-cleanup \
  --smoke-receipt ../../.artifacts/<run>/receipts/foundry-smoke.json \
  --access-receipt ../../.artifacts/<run>/receipts/foundry-access.json \
  --registration ../../.artifacts/<run>/receipts/foundry-attached.json \
  --expected-commit <full-lowercase-commit-sha> \
  --output ../../.artifacts/<run>/receipts/foundry-project-mi-cleanup.json
```

The same values can be supplied through `QAM_FOUNDRY_SMOKE_RECEIPT`,
`QAM_FOUNDRY_ACCESS_RECEIPT`, `QAM_FOUNDRY_ATTACHED_REGISTRATION`, and
`QAM_EXPECTED_COMMIT_SHA`. Use `qam-foundry-cleanup --help` for the complete CLI help.

The executing identity needs read access to the relevant Foundry ARM resources and Microsoft Graph,
permission to delete the old project connection, and permission to delete app-role assignments from
the Agent Application service principal. No client secret is accepted or stored.

## Receipt and idempotency

Success produces `qam-foundry-project-mi-cleanup/1.0` with phase `cleanup-verified`. It records the
verified commit, input evidence digests, bounded deletion counts, and the final invariant:

- exactly one Project Managed Identity `Qam.Read` assignment;
- zero Agent Application `Qam.Read` assignments; and
- no `qam-mcp-agent-identity` connection while the verified `qam-mcp-project-identity` connection
  remains present.

The command re-reads and verifies the final cloud state after deletion. Running it again with the
same valid evidence performs no deletion and emits another passed receipt with
`mutationPerformed=false`.
