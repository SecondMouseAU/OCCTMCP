---
title: Cookbook
nav_order: 2
has_children: true
---

# OCCTMCP Cookbook

Task-oriented, **example-rich** recipes for driving OCCTMCP from an MCP client (an LLM). One page per
area: a short bit of prose, then the actual **tool calls** — each shown as the JSON arguments you send
and an example JSON result you get back — chained into a real workflow. Figures for geometry-building
recipes are rendered by OCCTMCP's own `render_preview` and committed under `images/`.

This is the *usage* counterpart to the per-tool [Tool Reference](../../reference/); recipes link to the
reference rather than restating every parameter.

## Conventions

- **Show real tool calls.** Each step is a ```` ```json ```` block of the **arguments** object for one
  tool, optionally followed by a ```` ```json ```` **example result**. Use only real parameters (see the
  [Tool Reference](../../reference/) / the tool's schema) — never invent fields.
- **Typed tools first.** Reach for `execute_script` only when authoring geometry the typed tools don't
  cover; say so when you do, and keep scripts to the [script template](../../reference/core.md#execute_script).
- **One canonical place per topic.** Recipes hold *workflow*; per-tool detail lives in the
  [reference](../../reference/), architecture in [Architecture](../architecture.md). Link, don't duplicate.
- **Note the server.** When a recipe uses a Swift-only tool (selection / remap / annotations /
  reconstruct / `graph_select` / `pick_surface_point`), say it needs the Swift `occtmcp-server`.

## Figures & interactive 3D

OCCTMCP renders its own figures from the same tool calls the page shows, so code and figure never
drift. Build the scene with `execute_script` (or the typed construction tools), then:

- **PNG** via `render_preview` → committed under `images/` (also the loading poster below).
- **Interactive GLB** via `export_scene` (`format: "glb"`) → committed under `models/`, embedded with
  Google's [`<model-viewer>`](https://modelviewer.dev/) web component (orbit / zoom / auto-rotate),
  using the PNG as the poster until the model loads.

```html
<script type="module" src="https://cdn.jsdelivr.net/npm/@google/model-viewer/dist/model-viewer.min.js"></script>
<model-viewer src="models/<name>.glb" poster="images/<name>.png" alt="…"
  camera-controls auto-rotate environment-image="neutral" exposure="1.1" shadow-intensity="1"
  style="width:100%;max-width:480px;height:360px;background:#eef1f5;border-radius:6px"></model-viewer>
```

## Pages

- [Authoring with execute_script](authoring.md) — the script template, building geometry against the full OCCTSwift API, `get_script`, and the scene/manifest model.
- [Scene & appearance](scene-and-appearance.md) — read the scene, recolor / rename / remove bodies, and diff versions.
- [Construction](construction.md) — features (drill / fillet / chamfer / extrude / revolve / thread), transforms, booleans, and mirror / pattern.
- [Inspection](inspection.md) — validate geometry, compute metrics (volume / area / bbox / `boundingBoxOptimal`), query topology, and recognize features.
- [Measurement & verification](measurement.md) — minimum distance vs. surface deviation (Hausdorff) for certifying a reconstruction, wall thickness, and clearance.
- [Selection & remap](selection-and-remap.md) — pick faces / edges / vertices to stable `selectionId`s and carry them across mutations (Swift only).
- [Annotations & preview](annotations-and-preview.md) — dimensions, scene primitives, bounding boxes, diff overlays, and PNG previews / pixel picking (Swift only).
- [Import, export & assemblies](import-export.md) — load BREP / STEP / IGES (incl. `allowInvalid`), export the scene, and walk / edit XCAF assemblies.
- [Meshing & drawings](meshing-and-drawings.md) — tessellate, decimate, and produce multi-view technical drawings.
- [Healing](healing.md) — repair imported / non-watertight geometry and read before/after stats.
- [Topology graph](topology-graph.md) — validate / compact / dedup the B-rep graph, export ML-friendly JSON, and local adjacency / selection.
- [Reconstruction graph](reconstruction.md) — read/annotate/persist the attributed reconstruction graph (Swift only).
