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

The complete proof is an authorized tenant deployment, not an anonymous installer. Use an isolated
Azure resource group. The interactive Azure CLI **user** must also be:

- the Fabric capacity administrator named in the config;
- the Foundry operator and final smoke invoker;
- permitted to deploy the Bicep resources and the separately governed administrator template;
- permitted to create Entra applications, service principals, application roles, and app-role
  assignments, and to read the required Microsoft Graph objects;
- a Fabric tenant user with Capacity Contributor/Admin (or equivalent workspace-create permission
  on the selected capacity), allowed to create a Workspace, Lakehouse, Notebook, and Graph Model,
  and able to act as workspace Admin with delegated `Workspace.ReadWrite.All` for role updates and
  final cleanup; and
- allowed to publish the Foundry Agent Application and use the selected model deployment.

When the isolated resource group already exists and the required providers are registered, the
simplest Azure scope is Owner on that resource group. A narrower custom setup must still include
the deployment actions plus
`Microsoft.Authorization/roleAssignments/write` and
`Microsoft.Authorization/policyAssignments/write`. The interactive user normally also needs an
Entra Cloud Application Administrator or Application Administrator role for the identity stages.
Creating a new resource group additionally requires
`Microsoft.Resources/subscriptions/resourceGroups/write` at subscription scope. Registering a
provider requires the corresponding subscription-level provider-registration permission.

The Fabric tenant administrator must enable **Service principals can use Fabric APIs** for a scope
that includes the runtime managed identity and, when GitHub Actions deployment is used, the
deployment/OIDC service principal. When the setting is restricted to a security group, run only
through `foundation`, add the emitted runtime principal to that group, wait for propagation, and
then resume from `platform`. Fabric tenant/workspace permissions and Foundry model quota remain
separate tenant controls.

Install these operator tools before starting:

- Azure CLI with Bicep and the Container Apps extension;
- a POSIX environment with Bash, plus `git`, `curl`, `jq`, `uuidgen`, `base64`, and `openssl`;
- Node.js 22 and npm; and
- Python 3.11 or later and `uv`.

Docker is **not** required for this driver. ACR Tasks builds the image remotely from the exact
public Git SHA.

The example selects a Fabric F64 capacity and a Foundry model deployment. The selected region must
support Fabric capacity and have the requested model/version/quota. The driver does not delete
resources or pause the Fabric capacity at the end.

No Azure credential, GitHub token, client secret, `.env` file, or private key belongs in the
configuration. This public scenario fixes GitHub authentication to `none` and reads only the
public repository at the selected immutable commit.

## 1. Select the validated public source

The source commit must be anonymously readable, and the GitHub Actions workflow **QAM validate**
must have a successful `validate` check for that exact SHA. A private experiment branch, branch
name, or abbreviated SHA cannot be used.

Publish the reviewed commit, wait for validation, and then use a clean detached checkout:

```bash
git clone https://github.com/OWNER/REPOSITORY.git qam-public-proof
cd qam-public-proof
git checkout --detach '<40-lowercase-public-git-sha>'
git rev-parse HEAD
git status --short
```

The last command must print nothing. The driver requires `HEAD` to equal the configured SHA and
rechecks the public Git tree plus successful GitHub check before any driver-managed Azure mutation.
Because the validation workflow has path filters, a commit that changes only unrelated root files
may need an explicit `workflow_dispatch` on the default branch so the same SHA receives the check.

## 2. Prepare Azure and the separate deployment principal

Install the Azure CLI components, authenticate, and select the target subscription:

```bash
az bicep install
az extension add --name containerapp --upgrade
az login
az account set --subscription '<subscription-name-or-id>'
```

Register the resource providers used by the templates. This is a subscription mutation and needs
the corresponding registration permission:

```bash
for QAM_NAMESPACE in \
  Microsoft.App \
  Microsoft.ContainerRegistry \
  Microsoft.CognitiveServices \
  Microsoft.Fabric \
  Microsoft.Insights \
  Microsoft.KeyVault \
  Microsoft.ManagedIdentity \
  Microsoft.Network \
  Microsoft.OperationalInsights
do
  az provider register --namespace "${QAM_NAMESPACE}" --wait
done
```

The config requires a protected deployment/OIDC principal distinct from the managed identities
created later. If one does not already exist, the checked-in bootstrap can create the isolated
resource group, user-assigned identity/service principal, and an Azure federated credential scoped
to the named GitHub Environment. It grants that identity only resource-group Contributor:

```bash
quickagenticmemory/scripts/bootstrap-github-oidc.sh \
  --subscription-id '<azure-subscription-id>' \
  --resource-group '<new-or-existing-isolated-resource-group>' \
  --location '<supported-azure-region>' \
  --github-owner '<github-owner>' \
  --github-repository '<github-repository>' \
  --github-environment qam-test
```

Record the non-secret `AZURE_PRINCIPAL_ID` printed by the command. The interactive cloud driver
continues to authenticate as the signed-in user; the OIDC identity is the separately governed role
target and is used as the deployment caller only by the protected GitHub workflow.

The bootstrap does not create or protect the GitHub Environment. Before using the workflow, a
repository administrator must create `qam-test`, configure its reviewers and branch restrictions,
and add the non-secret variables printed by the bootstrap. The owner, repository, and Environment
must be controlled by the operator; use an operator-controlled public fork for reproduction and
never bind the Azure credential to a repository administered by someone else. This GitHub setup is
not required when the identity is used only as the separate role target for the interactive driver.

Display the signed-in user's UPN and object ID for the configuration:

```bash
az ad signed-in-user show \
  --query '{fabricAdminMember:userPrincipalName,objectId:id}' \
  --output json
```

## 3. Prepare the untracked configuration

Copy the reviewed example into the ignored artifacts directory:

```bash
mkdir -p quickagenticmemory/.artifacts
cp \
  quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-config.example.json \
  quickagenticmemory/.artifacts/cloud-config.json
```

Edit only the ignored copy. Required tenant-specific values are:

- public `OWNER/REPOSITORY`, canonical `.git` URL, and full lowercase 40-character SHA;
- subscription, isolated resource group, Azure region, and deployment environment;
- the signed-in user's UPN as `fabricAdminMember` and object ID as both operator and invoker;
- the bootstrap's distinct `AZURE_PRINCIPAL_ID` as `deploymentPrincipalId`;
- Fabric item names and a region-supported, tool-capable Foundry model name/version compatible with
  the configured `GlobalStandard` deployment; and
- for a first run, the signed-in user as `temporaryAcrWriter`. Set the entire value to `null` only
  when that user already has `Container Registry Repository Writer` on the created registry.

Set `foundry.mcpApiClientId` to an empty string to find or create the exact configured display
name. If the application already exists, supplying its client ID is safer. Leave
`image.expectedExistingDigest` empty for a first run; it is only an explicitly reviewed resume
assertion for an already locked image tag.

The scenario invariants must remain `image.repository = "qam-mcp"`,
`foundry.connectionName = "qam-mcp-project-identity"`,
`foundry.cleanupSupersededAccess = true`, and acceptance values 28 documents, 107 nodes, 167
edges, `IOL-M8`, and `XK8-IO`. The driver refuses angle-bracket placeholders, tracked config files,
branch names, abbreviated SHAs, mutable image tags, credential-bearing Git URLs, and configs
outside `.artifacts/`.

The operator, invoker, Fabric administrator, optional temporary ACR writer, and current Azure CLI
user are intentionally the same human for this executable proof. The deployment/OIDC principal
and runtime identity must remain distinct.

## 4. Run the complete proof

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

When **Service principals can use Fabric APIs** is restricted to a security group, stop after the
foundation creates the runtime identity. A security-group owner or authorized Entra administrator
must add that exact principal to the allowed group. An operator with that group-management
permission can run the command below, wait for Entra/Fabric propagation, and resume:

```bash
quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-run.sh \
  --config quickagenticmemory/.artifacts/cloud-config.json \
  --through-stage foundation

QAM_PUBLIC_SHA="$(git rev-parse HEAD)"
QAM_ARTIFACT_ROOT="quickagenticmemory/.artifacts/cloud-${QAM_PUBLIC_SHA:0:12}"
QAM_RUNTIME_PRINCIPAL_ID="$(jq -er \
  '.runtimeIdentityPrincipalId.value' \
  "${QAM_ARTIFACT_ROOT}/receipts/foundation.json")"

az ad group member add \
  --group '<fabric-api-enabled-security-group-object-id>' \
  --member-id "${QAM_RUNTIME_PRINCIPAL_ID}"

quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-run.sh \
  --config quickagenticmemory/.artifacts/cloud-config.json \
  --resume \
  --from-stage platform
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
| `platform` | `scripts/deploy-industrial-platform.sh`; Fabric/Foundry resources, isolated Fabric items, reviewed Preview roles, and real model inference |
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

Verify the terminal receipt from the same checkout:

```bash
QAM_PUBLIC_SHA="$(git rev-parse HEAD)"
QAM_ARTIFACT_ROOT="quickagenticmemory/.artifacts/cloud-${QAM_PUBLIC_SHA:0:12}"

jq -e '
  .receiptVersion == "qam-industrial-cloud-acceptance/1.0" and
  .status == "passed"
' "${QAM_ARTIFACT_ROOT}/receipts/cloud-acceptance.json"
```

A deliberately redacted receipt and screenshots from the successful public industrial run are
checked in under [`tests/industrial-component-obsolescence/screens/`](../tests/industrial-component-obsolescence/screens/).

Do not copy the raw receipts into `screens/` or commit them. A public evidence bundle must be built
from an explicit allowlist and omit subscription, tenant, resource, application, principal,
workspace, item, job, request, FQDN, registry, and local-path identifiers.

## Pause the Fabric capacity

The `cleanup` stage removes superseded Foundry/Entra access; it does not pause or delete deployed
resources. As soon as `receipts/industrial-platform.json` exists, use this lifecycle step after
acceptance **or after any later failure/interruption**. Read the exact capacity name from that
private receipt and pause it when no Fabric workload is using it:

```bash
QAM_CONFIG="quickagenticmemory/.artifacts/cloud-config.json"
QAM_PUBLIC_SHA="$(jq -er '.source.commitSha' "${QAM_CONFIG}")"
QAM_ARTIFACT_ROOT="quickagenticmemory/.artifacts/cloud-${QAM_PUBLIC_SHA:0:12}"
QAM_SUBSCRIPTION="$(jq -er '.azure.subscription' "${QAM_CONFIG}")"
QAM_RESOURCE_GROUP="$(jq -er '.azure.resourceGroup' "${QAM_CONFIG}")"
QAM_CAPACITY_NAME="$(jq -er \
  '.platform.fabricCapacityName' \
  "${QAM_ARTIFACT_ROOT}/receipts/industrial-platform.json")"

az account set --subscription "${QAM_SUBSCRIPTION}"

quickagenticmemory/scripts/manage-fabric-capacity.sh \
  --resource-group "${QAM_RESOURCE_GROUP}" \
  --capacity-name "${QAM_CAPACITY_NAME}" \
  --action suspend
```

If the platform deployment created the capacity but failed before writing
`industrial-platform.json`, resolve it from ARM instead. The proof resource group is isolated, so
review the list and continue only when it contains exactly the intended Fabric capacity:

```bash
QAM_CONFIG="quickagenticmemory/.artifacts/cloud-config.json"
QAM_SUBSCRIPTION="$(jq -er '.azure.subscription' "${QAM_CONFIG}")"
QAM_RESOURCE_GROUP="$(jq -er '.azure.resourceGroup' "${QAM_CONFIG}")"

az account set --subscription "${QAM_SUBSCRIPTION}"
az resource list \
  --resource-group "${QAM_RESOURCE_GROUP}" \
  --resource-type Microsoft.Fabric/capacities \
  --query '[].{name:name,location:location}' \
  --output table

QAM_CAPACITY_NAME='<reviewed-capacity-name>'
quickagenticmemory/scripts/manage-fabric-capacity.sh \
  --resource-group "${QAM_RESOURCE_GROUP}" \
  --capacity-name "${QAM_CAPACITY_NAME}" \
  --action suspend
```

Pausing makes assigned Fabric content unavailable but does not delete OneLake data, Foundry, or
the other deployed resources. Resume explicitly before another Fabric test:

```bash
QAM_CONFIG="quickagenticmemory/.artifacts/cloud-config.json"
QAM_SUBSCRIPTION="$(jq -er '.azure.subscription' "${QAM_CONFIG}")"
QAM_RESOURCE_GROUP="$(jq -er '.azure.resourceGroup' "${QAM_CONFIG}")"
QAM_PUBLIC_SHA="$(jq -er '.source.commitSha' "${QAM_CONFIG}")"
QAM_ARTIFACT_ROOT="quickagenticmemory/.artifacts/cloud-${QAM_PUBLIC_SHA:0:12}"
QAM_CAPACITY_NAME="$(jq -er \
  '.platform.fabricCapacityName' \
  "${QAM_ARTIFACT_ROOT}/receipts/industrial-platform.json")"

az account set --subscription "${QAM_SUBSCRIPTION}"
quickagenticmemory/scripts/manage-fabric-capacity.sh \
  --resource-group "${QAM_RESOURCE_GROUP}" \
  --capacity-name "${QAM_CAPACITY_NAME}" \
  --action resume
```

If `industrial-platform.json` was never written, repeat the ARM list/review step above and resume
with the reviewed name instead:

```bash
QAM_CONFIG="quickagenticmemory/.artifacts/cloud-config.json"
QAM_SUBSCRIPTION="$(jq -er '.azure.subscription' "${QAM_CONFIG}")"
QAM_RESOURCE_GROUP="$(jq -er '.azure.resourceGroup' "${QAM_CONFIG}")"
QAM_CAPACITY_NAME='<reviewed-capacity-name>'

az account set --subscription "${QAM_SUBSCRIPTION}"
quickagenticmemory/scripts/manage-fabric-capacity.sh \
  --resource-group "${QAM_RESOURCE_GROUP}" \
  --capacity-name "${QAM_CAPACITY_NAME}" \
  --action resume
```

## Reproducibility boundary

Anyone can inspect the public Markdown, source, workflow result, and redacted acceptance evidence.
Anyone with a suitably authorized Azure/Fabric tenant and regional model quota can run the same
driver in their own isolated resource group. A normal GitHub `workflow_dispatch` for other users
requires the reviewed workflow to exist on the repository's default branch; a public experiment
branch alone is not sufficient for that claim.

[Back to Quick Agentic Memory](../README.md)
