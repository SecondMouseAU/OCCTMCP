---
type: reference
title: References index
resource: https://github.com/SecondMouseAU/OCCTMCP
tags: [index, references]
description: SDK, docs, and upstream references for OCCTMCP.
timestamp: 2026-06-22
---

# References

- **Docs site** — in-repo `docs/` (Jekyll): `docs/index.md`, `docs/guides/`, `docs/reference/`.
- **MCP Swift SDK** — the official `modelcontextprotocol/swift-sdk`, the external MCP
  transport/protocol dependency. <https://github.com/modelcontextprotocol/swift-sdk> /
  <https://swiftpackageindex.com/modelcontextprotocol/swift-sdk>
- **OCCTSwift ecosystem map** — how OCCTMCP sits over the kernel, viewport, bridge, and AIS
  layers. <https://github.com/SecondMouseAU/OCCTSwift/blob/main/docs/ecosystem.md>
- **OpenCASCADE Technology (OCCT)** — the underlying C++ kernel (OCCT 8.0.0p1 cohort), reached
  via the OCCTSwift family. <https://dev.opencascade.org/>
- **OCCTReconstruct** — the reconstruction *engine* (surface fitting, congruence detection); the
  `reconstruct_*` tools here are the annotate-and-persist layer.
  <https://github.com/gsdali/OCCTReconstruct>
- **Swift Package Index** — package page (`main` is what SPI tracks; driven by `.spi.yml`).
- **License** — LGPL-2.1-or-later; see `LICENSE`.
