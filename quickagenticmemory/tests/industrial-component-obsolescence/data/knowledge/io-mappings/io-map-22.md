---
type: I/O Mapping
title: IO-MAP-22
description: PAL-80/V2 standard I/O assignment for the IOL-M8 process image.
status: stable
tags: [io-link, io-mapping, palletizing]
x-qam:
  uid: urn:qam:industrial:io-map:io-map-22
  aliases: [PAL V2 I/O map, V2 gripper sensor map]
generated:
  by: process:qam-industrial-fixture
  at: "2026-08-23T00:00:00Z"
---

# IO-MAP-22

This mapping assigns PAL-80/V2 gripper-open, gripper-closed, pallet-present, and layer-confirmed
devices to IOL-M8 ports. Their process values, status, and non-safety diagnostic records occupy
defined controller data fields; diagnostics are not modeled as dedicated physical ports.

Replacement validation must confirm symbolic channel assignment, input polarity, and diagnostic
byte interpretation using real site wiring.
