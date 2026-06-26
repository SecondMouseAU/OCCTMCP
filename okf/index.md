---
type: repo
title: OCCTMCP
resource: https://github.com/SecondMouseAU/OCCTMCP
tags: [mcp, llm, cad, occt, opencascade, swift, kernel]
description: An MCP server giving LLMs the ability to author, inspect, and iterate on 3D CAD models with OpenCASCADE via the OCCTSwift family.
timestamp: 2026-06-22
---

# OCCTMCP

An **MCP (Model Context Protocol) server** that gives LLMs the ability to author, inspect, and
iterate on 3D CAD models with [OpenCASCADE](https://www.opencascade.com/) via the
[OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) family. The primary Swift implementation
calls OCCT directly in-process (no subprocess, no JSONL marshalling) and exposes **59 typed MCP
tools** spanning authoring, scene reads/mutation, introspection, construction, analysis, I/O,
mesh, drawing, selection/remap, dimension overlays, and an attributed reconstruction graph.

The repo ships two implementations side-by-side: the **Swift** server (primary, 59 tools,
macOS 15+) and the original **Node / TypeScript** server (37 tools, shells out to `occtkit`).

## Role in the ecosystem

- **Cluster:** kernel
- **Depends on (intra-org):**
  [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift),
  [OCCTSwiftMesh](https://github.com/SecondMouseAU/OCCTSwiftMesh),
  [OCCTSwiftScripts](https://github.com/SecondMouseAU/OCCTSwiftScripts) (ScriptHarness +
  DrawingComposer),
  [OCCTSwiftTools](https://github.com/SecondMouseAU/OCCTSwiftTools),
  [OCCTSwiftViewport](https://github.com/SecondMouseAU/OCCTSwiftViewport),
  [OCCTSwiftAIS](https://github.com/SecondMouseAU/OCCTSwiftAIS).
- **External deps (not in `depends_on`):** the official
  [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) (MCP).
- **Feeds products:** none declared yet; the LLM-facing CAD surface over the OCCTSwift kernel.

## Components

See [`components/`](components/index.md) — the `OCCTMCPCore` library, the `occtmcp-server`
executable, and the tool catalogue.

## References

See [`references/`](references/index.md) — the published docs site, the MCP Swift SDK,
OpenCASCADE upstream, and the ecosystem map.

## Notes

- For geometry the typed tools don't cover, `execute_script` runs arbitrary Swift CAD code
  against the full OCCTSwift API, compiled and run in-process.
- SemVer-stable from v1.0.0 (Swift port reached v1.0.0 on 2026-05-09). Tracked on the Swift
  Package Index. LGPL-2.1-or-later, same as OCCTSwift.
- OCCT 8.0.0p1 cohort: deps floored at OCCTSwift 1.8.0 and the matching p1 sibling pins.

## Policies

- [Query `context` first for OCCT / OCCTSwift docs](policies/context-first.md)
- [Documentation updates are mandatory](policies/docs-current.md)
