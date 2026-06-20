---
title: Home
nav_order: 1
---

# OCCTMCP documentation

An **MCP server** that gives LLMs the ability to author, inspect, measure and iterate on 3D CAD models
with [OpenCASCADE](https://www.opencascade.com/) via the [OCCTSwift](https://github.com/gsdali/OCCTSwift)
family. The LLM picks a typed tool; OCCTMCP runs the OCCT operation in-process and writes BREP / STEP /
PNG + a `manifest.json` scene the viewer auto-reloads.

```json
// boolean_op — subtract one scene body from another
{ "op": "subtract", "aBodyId": "block", "bBodyId": "pin", "outputBodyId": "result" }
```

Two interchangeable servers read/write the same scene:

- **Swift** (`occtmcp-server`) — the **primary**, in-process server. **59 typed tools.** macOS 15+.
- **Node** (`dist/index.js`) — shells out to the `occtkit` CLI. **37-tool subset** (selection / remap /
  annotations / reconstruction are Swift-only). Runs anywhere Node 18+ does.

For geometry the typed tools don't cover, the LLM falls back to **`execute_script`**: arbitrary Swift
against the full OCCTSwift API, compiled and run in-process.

## Cookbook

Task-oriented recipes — prose plus the actual tool calls (arguments + example results), chained into
real workflows, with `render_preview` figures. The **[Cookbook index](guides/cookbook/)** lists all areas:

[Authoring](guides/cookbook/authoring.md) ·
[Scene & appearance](guides/cookbook/scene-and-appearance.md) ·
[Construction](guides/cookbook/construction.md) ·
[Inspection](guides/cookbook/inspection.md) ·
[Measurement & verification](guides/cookbook/measurement.md) ·
[Selection & remap](guides/cookbook/selection-and-remap.md) ·
[Annotations & preview](guides/cookbook/annotations-and-preview.md) ·
[Import / export](guides/cookbook/import-export.md) ·
[Meshing & drawings](guides/cookbook/meshing-and-drawings.md) ·
[Healing](guides/cookbook/healing.md) ·
[Topology graph](guides/cookbook/topology-graph.md) ·
[Reconstruction](guides/cookbook/reconstruction.md)

## Reference

- **[Tool Reference](reference/)** — per-tool-family detail: every tool's JSON-Schema parameters,
  returns, an example call + result, Node availability, and the OCCTSwift / occtkit behind it.
- [README tool table](https://github.com/gsdali/OCCTMCP#mcp-tools) — the one-line catalog.

## Guides & concepts

- [Getting started](guides/getting-started.md) — install, wire up `.mcp.json`, make your first call.
- [Architecture](guides/architecture.md) — the two servers, the manifest scene model, history & remap, the layered OCCTSwift ecosystem.

## Project

- Source & issues: [github.com/gsdali/OCCTMCP](https://github.com/gsdali/OCCTMCP)
- Part of the [OCCTSwift ecosystem](https://github.com/gsdali/OCCTSwift/blob/main/docs/ecosystem.md). SemVer-stable since v1.0.0.
