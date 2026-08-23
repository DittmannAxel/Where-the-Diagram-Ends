# Screens and evidence

This directory is the presentation layer of the proof.

- Screenshot files show the offline A/B report at a defined viewport.
- `evidence/latest/` contains machine-readable local run results, report data, the self-contained report, deterministic QAM projection artifacts, and a deliberately redacted cloud-status receipt.
- Cloud receipts contain only regions, public SKUs, deployment states, control outcomes, and public-safe source hashes. Real tenant, subscription, workspace, resource, job, application, and principal identifiers or names, tokens, credentials, local paths, and secret values must never be stored here.

A screenshot is supporting material, not the source of truth. For the offline experiment, [`run-results.json`](evidence/latest/run-results.json) and the deterministic projection [`manifest.json`](evidence/latest/qam-artifacts/manifest.json) at the recorded full Git SHA are the reproducible evidence. The public cloud receipt records redacted check outcomes; it is not a raw Azure or Fabric API response and cannot independently establish tenant or resource identity.

## Redacted cloud status

[`evidence/latest/cloud-deployment-receipt.json`](evidence/latest/cloud-deployment-receipt.json) records the public-safe outcome of the Azure, Fabric, Foundry, and GitHub OIDC checks. It intentionally omits all tenant-, subscription-, workspace-, resource-, principal-, application-, deployment-, and job-specific identifiers. The receipt keeps the Entra application-registration and Container Apps EasyAuth work marked `blocked`: the operator has Global Reader for discovery but not an Entra application-write role for registration, service-principal, federated-credential, or EasyAuth reconciliation.

## Captured views

- [`01-overview.png`](01-overview.png) shows the report overview, aggregate retrieval metrics, the 8/8 machine-readable acceptance result, and source-snapshot integrity.
- [`02-pkg-200-link-traversal.png`](02-pkg-200-link-traversal.png) shows selected case `Q-005-pkg-chain`: bounded bidirectional `LINKS_TO` paths beside the BM25 top-k list, followed by commit and acceptance evidence.

Both PNGs were captured from [`evidence/latest/report.html`](evidence/latest/report.html) at source commit `e0dd9b1fa0948075d640d440e913d24695d5b184` with Google Chrome `151.0.7922.170` in headless mode. The capture contract is a `1440 × 1200` viewport, device scale factor `1`, hidden scrollbars, and no external page assets. The overview uses document offset `0`; the detail selects tab `5` and captures a `1440 × 1200` clip beginning at `#impact-5`.

Current SHA-256 checksums:

```text
63e1245b0730f47b54a221d59d2e1248e3929d47876debf47a0c61910baf4632  01-overview.png
53bb97ccfdad689b84e1c8d657068dcf0155930a3feee4a598ac12d592bd3e4c  02-pkg-200-link-traversal.png
```
