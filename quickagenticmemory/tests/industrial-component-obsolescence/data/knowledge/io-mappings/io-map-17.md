---
type: I/O Mapping
title: IO-MAP-17
description: PKG-200/V500 standard I/O assignment for the IOL-M8 process image.
status: stable
tags: [io-link, io-mapping, packaging]
x-qam:
  uid: urn:qam:industrial:io-map:io-map-17
  aliases: [PKG V500 I/O map, V500 sensor map]
generated:
  by: process:qam-industrial-fixture
  at: "2026-08-23T00:00:00Z"
---

# IO-MAP-17

This mapping binds the IOL-M8 process image for PKG-200/V500. Ports 1–4 connect the carton-presence,
flap-position, glue-ready, and reject-confirmed devices; ports 5–8 are reserved for future standard
devices. Device status and diagnostic records are exposed in controller data, not assigned to
dedicated physical ports.

A replacement changes diagnostic byte layout and requires point-to-point verification of every
symbolic input before the variant is released. Direct physical addresses must not be copied into
application logic.
