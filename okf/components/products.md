---
type: component
title: Products and the tool catalogue
resource: https://github.com/SecondMouseAU/OCCTMCP/blob/main/Package.swift
tags: [component, products, spm, mcp-tools]
description: "The two Swift products (OCCTMCPCore library, occtmcp-server executable), the Node implementation beside them, and where the 79-tool catalogue lives."
generated: { by: human:gsdali, at: 2026-10-02 }
---

# Products and the tool catalogue

`OCCTMCP` exposes **two** Swift products (from `Package.swift`):

- **`OCCTMCPCore`** (`.library`, target `OCCTMCPCore`): the in-process tool implementation
  against OCCTSwift, OCCTSwiftMesh, `ScriptHarness` and `DrawingComposer` (OCCTSwiftScripts),
  OCCTSwiftInteraction (which vends `OCCTSwiftTools`, `OCCTSwiftAIS` and `OCCTSwiftCADKit`),
  OCCTSwiftViewport, plus the MCP SDK (`MCP` product of `swift-sdk`). An embedding host builds its
  server with `makeOCCTMCPServer(extraTools:outputDirectory:)`, which adds tools of its own (#196)
  and chooses the scene directory without touching the environment (#195).
- **`occtmcp-server`** (`.executable`, target `OCCTMCPServer`): the stdio MCP server binary;
  this is the `command` wired into an MCP client's `.mcp.json`.

A second, original **Node / TypeScript** implementation (`src/`, `package.json`) ships in the
same repo (37 tools, shells out to the `occtkit` CLI) but is not a Swift product. See
[the Node server](node-server.md).

## MCP tool catalogue (79 typed tools)

The categorized table lives in the repo's own `README.md`, not duplicated here: keeping one
copy is what stops the two from drifting apart as tools are added (the same duplication-drift
problem #125/#134 fixed elsewhere in this codebase). See
[README.md](https://github.com/SecondMouseAU/OCCTMCP#tools) for the current grouping
(authoring, scene reads/mutation, introspection, construction, engineering analysis,
mesh analysis (zones, alignment, curvature, mesh features), selection & remap (including the
agent-to-viewport-host selection bridge, #189/#190), annotations & overlays, I/O, visualisation,
topology graph, and the reconstruction graph tool group). What each file owns is in
[the Swift server, file by file](swift-server.md).
