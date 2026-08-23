# Reproduce the public-SHA cloud proof

This runbook deploys and tests the industrial component-obsolescence scenario from one exact,
publicly readable Git commit. The acceptance chain is:

```text
public Git SHA
  -> deterministic projection
  -> immutable OneLake staging
  -> Fabric Notebook + RefreshGraph + bounded GQL
  -> ACR remote build from the same public SHA
  -> digest-pinned Container App + Entra EasyAuth
  -> Foundry ProjectManagedIdentity MCP connection
  -> four-call resolve/traverse/provenance/read smoke
```

The checked-in driver is resumable, but it is intentionally not an anonymous installer. The
operator must be authorized to create the resources and identities in their own tenant. Raw
receipts contain tenant and resource identifiers and remain below the ignored
`quickagenticmemory/.artifacts/` boundary.

## What this proves

A passed `cloud-acceptance.json` proves that all of the following agreed on one full Git SHA:

- the public GitHub commit and its `data/knowledge/` Markdown tree;
- the projection manifest, OneLake publication, Fabric Notebook, refreshed Graph Model, and live
  bounded GQL result;
- the ACR Tasks build source, immutable image tag, locked digest, and deployed Container App image;
- the GitHub Contents read performed by the MCP service at the graph's commit;
- the published Foundry Agent Application's four ordered MCP events:
  `resolve_concepts`, `get_neighbors`, `trace_provenance`, and `read_concepts`.

It does not prove that an anonymous user can administer Azure, that the synthetic industrial data
represents a production machine, or that graphs universally outperform every RAG design.

## Prerequisites

Use an isolated, existing Azure resource group. The full driver currently expects an interactive
Azure CLI **user** who is also:

- the Fabric capacity administrator named in the config;
- the Foundry operator and final smoke invoker;
- permitted to deploy the Bicep resources and the separately governed administrator template;
- permitted to create Entra applications, service principals, application roles, and app-role
  assignments, and to read the required Microsoft Graph objects;
- a Fabric tenant user allowed to create a Workspace, Lakehouse, Notebook, and Graph Model; and
- allowed to publish the Foundry Agent Application and use the selected model deployment.

The administrator template requires the equivalent of
`Microsoft.Authorization/roleAssignments/write` and
`Microsoft.Authorization/policyAssignments/write`. The selected region needs Fabric capacity
support plus Foundry model availability and quota. The full showcase example selects F64; model name, version,
and capacity remain explicit tenant inputs because catalog and quota differ by region.

Install these management tools before starting:

- Azure CLI with Bicep and the Container Apps extension available;
- Node.js 22 and npm;
- Python 3.11 or later and `uv`;
- `git`, `curl`, `jq`, and `uuidgen`.

Sign in before running the driver:

```bash
az login
az account set --subscription '<subscription-name-or-id>'
```

No Azure credential, GitHub token, client secret, `.env` file, or private key belongs in the
configuration. This public scenario fixes GitHub authentication to `none` and reads only the
public repository at the selected immutable commit.

## Prepare an untracked configuration

Run from a clean checkout of the exact public commit that will be tested. Copy the reviewed example
into the ignored artifacts directory:

```bash
mkdir -p quickagenticmemory/.artifacts
cp \
  quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-config.example.json \
  quickagenticmemory/.artifacts/cloud-config.json
```

Edit only the ignored copy. Required tenant-specific values are:

- subscription, existing resource group, Azure region, and deployment environment;
- the signed-in Fabric administrator UPN and user object ID;
- a distinct GitHub OIDC service-principal object ID for deployment/Fabric publication;
- the public `OWNER/REPOSITORY`, canonical `.git` URL, and full lowercase 40-character SHA;
- Fabric item names and the region-supported Foundry model name/version/capacity;
- optionally, an existing MCP API application client ID;
- optionally, the signed-in user's object ID as `temporaryAcrWriter` when that user does not
  already have ACR Repository Writer; the build helper creates and removes exactly one
  short-lived assignment; and
- optionally, an explicitly reviewed digest when resuming an already locked image tag.

Set `foundry.mcpApiClientId` to an empty string to find or create the exact configured display
name. If the application already exists, supplying its client ID is safer. The driver refuses
angle-bracket placeholders, tracked config files, branch names, abbreviated SHAs, mutable image
tags, image repositories other than the deployment contract's fixed `qam-mcp`, credential-bearing
Git URLs, and configs outside `.artifacts/`.

The operator, invoker, Fabric administrator, and current Azure CLI user are intentionally the same
human for this executable proof. The runtime managed identity is created by the foundation. The
deployment/OIDC principal and runtime principal must remain distinct.

## Require the public source and cloud validation first

The source commit must already be available anonymously, and the `QAM validate` GitHub Actions job
must have succeeded for that exact SHA. The driver verifies both through unauthenticated GitHub
APIs before any Azure mutation. It also requires the local checkout's tracked files to be clean and
`HEAD` to equal the configured SHA.

This means a private experiment branch cannot be used. Publish only the reviewed commit, wait for
its validation run, and then execute the proof from a fresh clone or detached checkout:

```bash
git clone https://github.com/OWNER/REPOSITORY.git qam-public-proof
cd qam-public-proof
git checkout --detach '<40-lowercase-public-git-sha>'
```

## Run the complete proof

The one-command entry point is:

```bash
quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-run.sh \
  --config quickagenticmemory/.artifacts/cloud-config.json
```

It prints the ignored final receipt path only after every stage passes. It performs no mandatory
preview, no local Docker build, and no local A/B evaluation. The only local compilation is the
deterministic Core projector; its outputs are then loaded and accepted in Fabric. The deployable
container is built by Azure Container Registry Tasks directly from
`https://github.com/OWNER/REPOSITORY.git#FULL_SHA`.

The ordered stages are:

```text
preflight
foundation
platform
projection
fabric
image
mcp-api
identity
access
application
invoker
attach
smoke
cleanup
acceptance
```

List them from the script:

```bash
quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-run.sh --list-stages
```

### Staged execution and resume

Long cloud operations can be split at reviewed boundaries:

```bash
# Provision/reconcile through the Fabric proof.
quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-run.sh \
  --config quickagenticmemory/.artifacts/cloud-config.json \
  --through-stage fabric

# Verify every earlier marker and continue from the immutable cloud image.
quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-run.sh \
  --config quickagenticmemory/.artifacts/cloud-config.json \
  --resume \
  --from-stage image
```

Every completed stage has a SHA- and config-bound marker. `--resume` verifies the stage receipt
before skipping its mutation. A marker whose config or commit differs fails closed. If a process
stops after a valid receipt was written but before its marker, resume recovers that exact receipt.
If an ACR tag exists without a valid local receipt, set `image.expectedExistingDigest` only after
reviewing its provenance and locks. That single resume-only assertion is excluded from the marker
hash so it can be added after an interrupted build; every deployment, identity, source, platform,
and acceptance field remains marker-bound.

Typical durations are tenant-dependent. A platform reconciliation is often several minutes;
Fabric Notebook plus `RefreshGraph` can take 6–10 minutes; ACR remote build is usually 1–3 minutes;
and Container Apps plus Foundry identity/attach can each take several minutes. Every helper uses a
bounded poll and exits nonzero on unknown or terminal failure states.

After `RefreshGraph`, live GQL uses 60 attempts with a 30-second interval by default so a retriable
capacity `429` can settle. Authorized operators may set `QAM_FABRIC_GRAPH_QUERY_ATTEMPTS` and
`QAM_FABRIC_GRAPH_QUERY_RETRY_SECONDS`; both are validated and bounded before publication, and the
last failed attempt exits nonzero without running acceptance cleanup.

## What the driver invokes

The driver composes the checked-in, independently testable helpers rather than reproducing their
cloud logic:

| Stage | Checked-in implementation and gate |
| --- | --- |
| `foundation` | `scripts/deploy.sh --skip-app`, followed by the isolated `--include-role-assignments` administrator template |
| `platform` | `scripts/deploy-industrial-platform.sh`; paid Fabric/Foundry resources, isolated Fabric items, reviewed Preview roles, and real model inference |
| `projection` | Core `project` command over the public scenario checkout; manifest must contain the configured repository and full SHA |
| `fabric` | `scripts/publish-industrial-fabric.sh --acceptance-cleanup`; immutable OneLake staging, Notebook, canonical definition, official `RefreshGraph`, bounded GQL, and updater downgrade to exactly one Viewer assignment |
| `image` | `scripts/build-cloud-image.sh`; ACR remote Git build, exact run digest, manifest write/delete locks, and verified temporary-writer cleanup |
| `mcp-api` | `scripts/bootstrap-mcp-entra.sh --prepare-only`; single-tenant API, v2 access tokens, `Qam.Read`, and assignment-required service principal |
| `identity` | tool-less `qam-foundry-register identity`; stable Agent Application identity plus separately derived Foundry project system identity |
| `access` | `configure-access.sh`; `Qam.Read` only for the project managed identity |
| `application` | digest-pinned `scripts/deploy.sh`; Fabric GQL, public GitHub Contents, two UAMIs, and EasyAuth allowlists containing only the project client/principal |
| `attach` | `qam-foundry-register attach`; `ProjectManagedIdentity` RemoteTool and exactly seven bounded read-only QAM tools |
| `smoke` | `qam-foundry-smoke`; exactly four nonparallel events, exact commit propagation, and literal content marker proof |
| `cleanup` | reviewed `qam_foundry.cleanup`; only after passed smoke, removes superseded Agent Application `Qam.Read` and the old `qam-mcp-agent-identity` connection, then proves one project-MI grant and zero app grants |

The EasyAuth boundary is exact: HTTPS is required, only `/healthz` is anonymous, all other
unauthenticated calls return `401`, audience/client/principal must match, and
`allowedPrincipals` contains only `identities`. Even an empty `groups` key is rejected because it
changes the app-only authorization path.

## Acceptance and evidence

Private machine-readable receipts are written below:

```text
quickagenticmemory/.artifacts/cloud-<sha-prefix>/
├── receipts/
├── stages/
├── public-source/
├── industrial-projection/
└── fabric-definition/
```

The terminal receipt is `receipts/cloud-acceptance.json`. It is emitted only when:

- public source and GitHub Actions validation are green at the exact commit;
- Fabric reports the configured node/edge counts at that commit;
- the image was remotely built, digest-pinned, and locked;
- Container Apps has exactly one active healthy revision, two user-assigned identities, health
  `200`, and anonymous MCP `401`;
- EasyAuth contains only the project managed identity client/principal;
- Foundry reports exactly the four required QAM events and the expected content marker; and
- post-smoke cleanup proves one project-MI `Qam.Read`, zero Agent Application `Qam.Read`, and the
  active `ProjectManagedIdentity` connection.

A deliberately redacted receipt and screenshots from the successful public industrial run are
checked in under [`tests/industrial-component-obsolescence/screens/`](../tests/industrial-component-obsolescence/screens/).

Do not copy the raw receipts into `screens/` or commit them. A public evidence bundle must be built
from an explicit allowlist and omit subscription, tenant, resource, application, principal,
workspace, item, job, request, FQDN, registry, and local-path identifiers.

## Reproducibility boundary

Anyone can inspect the public Markdown, source, workflow result, and redacted acceptance evidence.
Anyone with a suitably authorized Azure/Fabric tenant and regional model quota can run the same
driver in their own isolated resource group. A normal GitHub `workflow_dispatch` for other users
requires the reviewed workflow to exist on the repository's default branch; a public experiment
branch alone is not sufficient for that claim.

[Back to Quick Agentic Memory](../README.md)
