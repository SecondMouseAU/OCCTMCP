---
title: Tool Reference
nav_order: 3
has_children: true
---

# OCCTMCP Tool Reference

A **detailed, per-tool reference** for the OCCTMCP MCP surface — one page per *tool family*, every
tool documented: what it does, its JSON-Schema parameters, what it returns, a runnable example call
with an example response, the underlying OCCTSwift / occtkit it drives, and gotchas.

OCCTMCP is an **MCP server**, not a library: clients call these tools over stdio MCP, each with a
single JSON-object argument, and get JSON text back. The **Swift** server (`occtmcp-server`) is the
canonical 73-tool surface documented here; the **Node** server exposes a 37-tool subset — each tool
notes its Node availability.

This complements the other docs:
- [Cookbook](../guides/cookbook/) — *task-oriented* recipes that chain these tools.
- [README tool table](https://github.com/SecondMouseAU/OCCTMCP#mcp-tools) — the one-line catalog.

## Page layout

One file `docs/reference/<family>.md` per tool family. Each page:

```markdown
---
title: <Family>
parent: Tool Reference
nav_order: <n>
---

# <Family>

<1–3 sentences: what this family is for and when an LLM reaches for it.>

## Tools

- [`tool_a`](#tool_a) · [`tool_b`](#tool_b) · …

---

## `tool_name`     ← one `##` per tool, in the page's tool order

<one-line summary — what it does.>

**Server:** Swift + Node   *(or)*   Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | … |
| `metrics` | string[] | no | … |

<omit the row's table entirely if the tool takes no arguments; say "No parameters.">

**Returns** — <what the JSON result contains; note error conditions.>

**Example**

​```json
// tool call arguments
{ "bodyId": "part", "metrics": ["volume", "boundingBoxOptimal"] }
​```
​```json
// example result
{ "volume": 1000.0, "boundingBoxOptimal": { "min": [0,0,0], "max": [10,10,10] } }
​```

**Notes** — gotchas / cross-references. *(omit if none)*
**Drives** — the OCCTSwift call / occtkit verb behind it. *(omit if unknown)*
```

## Entry rules (the contract)

1. **Parameters come verbatim from the JSON Schema** provided to you (`docs-build/schemas/<family>.json`)
   — names, types, `required`, and the schema `description`. Do not invent or rename parameters.
2. **Every tool in the family file gets one `##` section**, in the order listed in that file.
3. **`Server:` line is required** — use the `nodeAvailable` flag in the schema: `Swift + Node` when
   true, `Swift only` when false.
4. **Examples must be schema-faithful** — only real parameters, correct types. Keep them minimal and
   realistic (a `bodyId` like `"part"`, a path under the output dir). Mark illustrative result JSON as
   an example; don't over-specify exact numbers you can't know.
5. **No invention.** Behaviour comes from the schema `description`, the [README](https://github.com/SecondMouseAU/OCCTMCP#mcp-tools),
   and the architecture notes in your prompt. If a detail is unclear, state it briefly — don't fabricate.
6. **Concise.** Reference, not prose: one summary line, a parameter table, returns, one example.

## Families

| Page | Tools |
|------|-------|
| [Core & scripting](core.md) | execute_script, get_script, get_scene, export_model, get_api_reference, ping |
| [Scene mutation](scene-mutation.md) | remove_body, clear_scene, rename_body, set_appearance, compare_versions |
| [Introspection & measurement](introspection.md) | validate_geometry, compute_metrics, query_topology, measure_distance, measure_deviation, recognize_features, inspect_assembly |
| [Construction](construction.md) | apply_feature, transform_body, boolean_op, mirror_or_pattern |
| [Engineering analysis](engineering.md) | check_thickness, analyze_clearance, heal_shape |
| [Selection & remap](selection.md) | select_topology, remap_selection, find_correspondences, select_by_feature, list_selections, clear_selections |
| [Annotations & overlays](annotations.md) | add_dimension, add_scene_primitive, auto_dimension, show_bounding_box, diff_overlay, remove_scene_annotation, list_annotations |
| [I/O](io.md) | read_brep, import_file, export_scene, set_assembly_metadata |
| [Mesh & visualization](mesh-visualization.md) | generate_mesh, simplify_mesh, render_preview, pick_surface_point, generate_drawing |
| [Mesh analysis (zones)](mesh-analysis.md) | segment_mesh_zones, zone_continuity_sweep, list_zones, clear_zones, mesh_diagnose, mesh_thickness, detect_symmetry, align_bodies |
| [Topology graph](topology-graph.md) | graph_validate, graph_compact, graph_dedup, graph_ml, graph_select, feature_recognize |
| [Reconstruction graph](reconstruction.md) | reconstruct_get_graph, reconstruct_set_decision, reconstruct_force_fit, reconstruct_confirm_instances, reconstruct_export_session, reconstruct_import_session |
