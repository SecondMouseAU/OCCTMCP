---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTMCP
tags: [index, api, mcp-tools]
description: OCCTMCP products — OCCTMCPCore library, occtmcp-server executable, and the 59-tool catalogue.
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

## MCP tool catalogue (59 typed tools)

Grouped as in the README:

- **Authoring** — `execute_script`, `get_script`, `get_api_reference`
- **Scene reads** — `get_scene`, `export_model`, `compare_versions`
- **Scene mutation** — `remove_body`, `clear_scene`, `rename_body`, `set_appearance`
- **Introspection** — `validate_geometry`, `compute_metrics`, `query_topology`,
  `measure_distance`, `measure_deviation`, `recognize_features`, `inspect_assembly`
- **Construction** — `apply_feature`, `transform_body`, `boolean_op`, `mirror_or_pattern`
- **Engineering analysis** — `check_thickness`, `analyze_clearance`, `heal_shape`
- **Selection & remap** — `select_topology`, `remap_selection`, `find_correspondences`,
  `select_by_feature`, `list_selections`, `clear_selections`
- **Annotations & overlays** — `add_dimension`, `add_scene_primitive`, `auto_dimension`,
  `show_bounding_box`, `diff_overlay`, `remove_scene_annotation`, `list_annotations`
- **I/O** — `read_brep`, `import_file`, `export_scene`, `set_assembly_metadata`
- **Mesh & visualisation** — `generate_mesh`, `simplify_mesh`, `render_preview`,
  `pick_surface_point`, `generate_drawing`
- **Topology graph (low-level)** — `graph_validate`, `graph_compact`, `graph_dedup`,
  `graph_ml`, `graph_select`, `feature_recognize`
- **Reconstruction graph (read/write)** — `reconstruct_get_graph`, `reconstruct_set_decision`,
  `reconstruct_force_fit`, `reconstruct_confirm_instances`, `reconstruct_export_session`,
  `reconstruct_import_session`
