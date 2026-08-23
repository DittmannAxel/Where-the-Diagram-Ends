---
type: PLC Function Block
title: FB_PALLET_DIAG
description: PAL-80/V2 diagnostic block coupled to the IOL-M8 process image.
status: stable
tags: [diagnostics, palletizing, plc]
x-qam:
  uid: urn:qam:industrial:plc:fb-pallet-diag
  aliases: [PAL IO diagnostics, V2 pallet diagnostic FB]
generated:
  by: process:qam-industrial-fixture
  at: "2026-08-23T00:00:00Z"
---

# FB_PALLET_DIAG

`FB_PALLET_DIAG` evaluates IOL-M8 device state for the PAL-80/V2 gripper and pallet sensors. A
valid migration must preserve the distinction between missing device, bad parameter set, and
channel short circuit.

The block is ordinary diagnostics logic; it has no authority over the independent safety system.
