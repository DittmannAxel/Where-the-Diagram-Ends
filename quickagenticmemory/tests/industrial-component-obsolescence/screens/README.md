# Screens and evidence

This directory is the presentation layer of the proof.

- Screenshot files show both the offline A/B report and the successful cloud acceptance proof.
- `evidence/latest/` contains machine-readable local run results, report data, the self-contained local report, deterministic QAM projection artifacts, a self-contained cloud-proof page, and a deliberately redacted cloud-acceptance receipt.
- Cloud receipts contain only regions, public SKUs, deployment states, control outcomes, and public-safe source hashes. Real tenant, subscription, workspace, resource, job, application, and principal identifiers or names, tokens, credentials, local paths, and secret values must never be stored here.

A screenshot is supporting material, not the source of truth. For the offline experiment, [`run-results.json`](evidence/latest/run-results.json) and the deterministic projection [`manifest.json`](evidence/latest/qam-artifacts/manifest.json) at the recorded full Git SHA are the reproducible evidence. The public cloud receipt records redacted check outcomes; it is not a raw Azure or Fabric API response and cannot independently establish tenant or resource identity.

## Redacted cloud acceptance

[`evidence/latest/cloud-deployment-receipt.json`](evidence/latest/cloud-deployment-receipt.json) records the public-safe outcome of the complete Azure, Fabric, Entra, Container Apps, GitHub, and Foundry chain at source commit `ae3b513f3c3c549874a476ca020d1ff5a6fcf436`. The status is `passed`: the public 28-document corpus produced 107 nodes and 167 edges, live GQL passed, anonymous MCP returned `401`, EasyAuth allowed only the Foundry project managed identity, and the Foundry Agent Application completed the required four-tool trace plus exact-commit source read. It intentionally omits every tenant-, subscription-, workspace-, resource-, principal-, application-, deployment-, job-, request-, registry-, digest-, and hostname-specific identifier.

[`evidence/latest/cloud-proof.html`](evidence/latest/cloud-proof.html) is the self-contained presentation view used for the cloud screenshots. It contains only the same allowlisted public facts as the receipt.

## Captured views

- [`01-overview.png`](01-overview.png) shows the report overview, aggregate retrieval metrics, the 8/8 machine-readable acceptance result, and source-snapshot integrity.
- [`02-pkg-200-link-traversal.png`](02-pkg-200-link-traversal.png) shows selected case `Q-005-pkg-chain`: bounded bidirectional `LINKS_TO` paths beside the BM25 top-k list, followed by commit and acceptance evidence.
- [`03-public-github-data.jpg`](03-public-github-data.jpg) shows the public GitHub `data/knowledge` directory at the exact cloud-tested commit.
- [`04-cloud-chain-acceptance.jpg`](04-cloud-chain-acceptance.jpg) shows the complete redacted cloud acceptance chain and its live boundary checks.
- [`05-foundry-agent-smoke.jpg`](05-foundry-agent-smoke.jpg) shows the authenticated four-event Foundry tool trace and the verified security controls.

The first two PNGs were captured from [`evidence/latest/report.html`](evidence/latest/report.html) at source commit `e0dd9b1fa0948075d640d440e913d24695d5b184` with Google Chrome `151.0.7922.170` in headless mode. The capture contract is a `1440 × 1200` viewport, device scale factor `1`, hidden scrollbars, and no external page assets. The overview uses document offset `0`; the detail selects tab `5` and captures a `1440 × 1200` clip beginning at `#impact-5`.

The cloud JPEGs were captured after the successful run at source commit `ae3b513f3c3c549874a476ca020d1ff5a6fcf436`. The GitHub view is `1280 × 720`; the self-contained cloud proof is a `1280 × 1807` full-page capture; the Foundry trace is a `1216 × 477` element clip. The cloud proof has no external page assets.

Current SHA-256 checksums:

```text
63e1245b0730f47b54a221d59d2e1248e3929d47876debf47a0c61910baf4632  01-overview.png
53bb97ccfdad689b84e1c8d657068dcf0155930a3feee4a598ac12d592bd3e4c  02-pkg-200-link-traversal.png
f26b5cbf9152be710208523f8428e6a638e606e52fbb1fc20fba298a9ad7ed59  03-public-github-data.jpg
a77903630d0088c92e4d6842f4bc6e774c527a868d370d175ef774b5a49f74a6  04-cloud-chain-acceptance.jpg
6d1d00e1cccc5f41587c3fb201566b17f26df61f01276bbb45a256db462f904d  05-foundry-agent-smoke.jpg
```
