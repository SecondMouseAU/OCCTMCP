---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTMCP
tags: [index, api, mcp-tools]
description: OCCTMCP products — OCCTMCPCore library, occtmcp-server executable, and the 79-tool catalogue.
timestamp: 2026-06-22
---

# Components

`OCCTMCP` exposes **two** Swift products (from `Package.swift`):

- **`OCCTMCPCore`** (`.library`, target `OCCTMCPCore`) — the in-process tool implementation
  against OCCTSwift / OCCTSwiftMesh / ScriptHarness + DrawingComposer (OCCTSwiftScripts) /
  OCCTSwiftTools / OCCTSwiftViewport / OCCTSwiftAIS, plus the MCP SDK (`MCP` product of
  `swift-sdk`).
- **`occtmcp-server`** (`.executable`, target `OCCTMCPServer`) — the stdio MCP server binary;
  this is the `command` wired into an MCP client's `.mcp.json`.

A second, original **Node / TypeScript** implementation (`src/`, `package.json`) ships in the
same repo (37 tools, shells out to the `occtkit` CLI) but is not a Swift product.

## MCP tool catalogue (79 typed tools)

The categorized table lives in the repo's own `README.md`, not duplicated here: keeping one
copy is what stops the two from drifting apart as tools are added (the same duplication-drift
problem #125/#134 fixed elsewhere in this codebase). See
[README.md](https://github.com/SecondMouseAU/OCCTMCP#tools) for the current grouping
(authoring, scene reads/mutation, introspection, construction, engineering analysis,
mesh analysis (zones, alignment, curvature, mesh features), selection & remap (including the
agent-to-viewport-host selection bridge, #189/#190), annotations & overlays, I/O, visualisation,
topology graph, and the reconstruction graph tool group).
