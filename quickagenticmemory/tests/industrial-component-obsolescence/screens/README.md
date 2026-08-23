# Screens and evidence

This directory is the presentation layer of the proof.

- Screenshot files show the offline A/B report at a defined viewport.
- `evidence/latest/` contains machine-readable local run results, report data, the self-contained report, and deterministic QAM projection artifacts.
- Cloud receipts contain only redacted resource names, regions, deployment state, control outcomes, and timestamps. Tenant IDs, subscription IDs, object IDs, tokens, credentials, and secret values must never be stored here.

A screenshot is supporting material, not the source of truth. The JSON receipt and its full Git SHA are the authoritative evidence, and the test runner must be able to reproduce them from the tracked corpus.
