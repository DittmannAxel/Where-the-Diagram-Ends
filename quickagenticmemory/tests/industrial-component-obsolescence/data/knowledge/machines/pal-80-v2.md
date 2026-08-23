---
type: Machine Variant
title: PAL-80/V2
description: Delivered PAL-80 variant directly using IOL-M8.
status: stable
tags: [delivered, machine-variant, palletizing]
x-qam:
  uid: urn:qam:industrial:machine-variant:pal-80-v2
  aliases: [PAL 80 V2, PAL-V2]
generated:
  by: process:qam-industrial-fixture
  at: "2026-08-23T00:00:00Z"
---

# PAL-80/V2

The delivered synthetic assets `PAL-80-0207` and `PAL-80-0208` directly use
[IOL-M8](../components/iol-m8.md) for standard gripper and pallet sensor diagnostics. Their safety
functions use a separate subsystem outside this replacement assessment.

Impact-controlled artifacts are [IO-MAP-22](../io-mappings/io-map-22.md),
[FB_PALLET_DIAG](../plc/fb-pallet-diag.md), [PARAM-SET-09](../parameters/param-set-09.md),
[FAT-057](../acceptance-tests/fat-057.md), and [SAT-011](../acceptance-tests/sat-011.md).
The variant belongs to the [PAL-80 family](pal-80.md).
