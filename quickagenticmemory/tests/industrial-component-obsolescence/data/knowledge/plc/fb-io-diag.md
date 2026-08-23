---
type: PLC Function Block
title: FB_IO_DIAG
description: PKG-200/V500 diagnostic block coupled to the IOL-M8 process image.
status: stable
tags: [diagnostics, plc, structured-text]
x-qam:
  uid: urn:qam:industrial:plc:fb-io-diag
  aliases: [PKG IO diagnostics, V500 diagnostic FB]
generated:
  by: process:qam-industrial-fixture
  at: "2026-08-23T00:00:00Z"
---

# FB_IO_DIAG

`FB_IO_DIAG` reads the symbolic diagnostic bytes defined by IO-MAP-17 and raises a maintenance
event for port loss, short circuit, or device mismatch. It runs in the slow diagnostic task and
does not perform deterministic motion or safety control.

The replacement assessment must adapt status-word decoding and regression-test alarm suppression
during machine reset.
