---
okf_version: "0.2"
---

# Industrial component-obsolescence fixture

> **Fictional test data.** Every company, product, article number, machine, serial number,
> document, date, and engineering decision in this bundle is synthetic. It is designed for a
> public retrieval benchmark and must not be used to operate, modify, validate, or certify real
> machinery.

The bundle models the announced end of life of the fictional, non-safety-related IO-Link master
`IOL-M8`. The expected impact is intentionally distributed over machine variants, I/O mappings,
PLC diagnostics, parameter sets, and FAT/SAT cases. `IOL-M8S` is a separate and incompatible
distractor; its `S` suffix means *stainless enclosure*, not a safety function.

## Components

- [IOL-M8](components/iol-m8.md) — Obsolete component under investigation.
- [IOL-M8S](components/iol-m8s.md) — Similar-looking but distinct distractor.
- [NXL-R8](components/nxl-r8.md) — Candidate replacement pending validation.

## Machine families and variants

- [PKG-200 family](machines/pkg-200.md) — Synthetic packaging platform.
- [PKG-200/V500](machines/pkg-200-v500.md) — Impacted delivered variant.
- [PKG-200/V300](machines/pkg-200-v300.md) — Unaffected variant.
- [PAL-80 family](machines/pal-80.md) — Synthetic palletizing platform.
- [PAL-80/V2](machines/pal-80-v2.md) — Impacted delivered variant.
- [PAL-80/V1](machines/pal-80-v1.md) — Distractor using IOL-M8S.

## Engineering artifacts

- [IO-MAP-17](io-mappings/io-map-17.md) — PKG-200/V500 I/O assignment.
- [IO-MAP-22](io-mappings/io-map-22.md) — PAL-80/V2 I/O assignment.
- [IO-MAP-S08](io-mappings/io-map-s08.md) — IOL-M8S distractor mapping.
- [FB_IO_DIAG](plc/fb-io-diag.md) — PKG diagnostics.
- [FB_PALLET_DIAG](plc/fb-pallet-diag.md) — PAL diagnostics.
- [FB_STAINLESS_DIAG](plc/fb-stainless-diag.md) — IOL-M8S distractor diagnostics.
- [PARAM-SET-17](parameters/param-set-17.md) — PKG parameters.
- [PARAM-SET-09](parameters/param-set-09.md) — PAL parameters.
- [PARAM-SET-S08](parameters/param-set-s08.md) — IOL-M8S distractor parameters.

## Change control and notices

- [CR-1042](change-requests/cr-1042.md) — Controlled replacement assessment.
- [SB-2026-04](service-bulletins/sb-2026-04.md) — Current IOL-M8 notice.
- [SB-2024-11](service-bulletins/sb-2024-11.md) — Superseded recommendation.
- [SB-2026-S08](service-bulletins/sb-2026-s08.md) — Unrelated IOL-M8S notice.

## Acceptance tests

- [FAT-042](acceptance-tests/fat-042.md) — PKG I/O diagnostics.
- [SAT-021](acceptance-tests/sat-021.md) — PKG site recovery.
- [FAT-057](acceptance-tests/fat-057.md) — PAL I/O diagnostics.
- [SAT-011](acceptance-tests/sat-011.md) — PAL site recovery.
- [FAT-099](acceptance-tests/fat-099.md) — IOL-M8S distractor test.
