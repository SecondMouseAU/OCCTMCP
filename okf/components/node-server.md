---
type: component
title: The Node server
resource: https://github.com/SecondMouseAU/OCCTMCP/tree/main/src
tags: [component, node, typescript, occtkit, mcp]
description: The original Node/TypeScript implementation, file by file: what each module owns, how occtkit is resolved and served, and which tool surface it deliberately does not carry.
generated: { by: human:gsdali, at: 2026-09-06 }
---

# The Node server

The Node server is a single-process Node.js app (ESM, strict TypeScript):

- `src/index.ts`: `createServer()` factory + stdio binding
- `src/tools.ts`: Core: `execute_script`, `get_scene`, `get_script`, `export_model`, `get_api_reference`. Delegates to a long-lived `occtkit run --serve` child by default, falls back to one-shot `occtkit run <path>` if serve mode is unavailable
- `src/scene-tools.ts`: Pure-TS scene-mutation tools (`remove_body`, `clear_scene`, `rename_body`, `set_appearance`, `compare_versions`, `export_scene`). `export_scene` is the exception: generates a one-shot Swift script run via `occtkit run`. Maintains an in-memory ring buffer of the last 10 manifest snapshots for `compare_versions`
- `src/api-tools.ts`: Wrappers around occtkit verbs (`validate_geometry` → `graph-validate`, `recognize_features` → `feature-recognize`, `apply_feature` → `reconstruct`, `generate_drawing` → `drawing-export`)
- `src/verb-tools.ts`: Wrappers around the rest of the occtkit verbs (compute_metrics / query_topology / measure_distance / check_thickness / analyze_clearance / generate_mesh / transform_body / boolean_op / mirror_or_pattern / heal_shape / read_brep / import_file / render_preview)
- `src/occtkit.ts`: Resolves how to invoke `occtkit`: prefers PATH, falls back to `swift run -c release occtkit` inside the sibling OCCTSwiftScripts repo
- `src/occtkit-serve.ts`: Singleton long-lived `occtkit run --serve` child. JSONL request/response over stdin/stdout. Per-request timeout kills the child and respawns on next call
- `src/paths.ts`: Same resolution rules as the Swift `Paths.swift`
- `src/api-reference.ts`: **Generated** OCCTSwift API reference, rewritten by `scripts/generate-api-reference.mjs` (runs as `npm run prebuild`). Parses `~/Projects/OCCTSwift/Sources/OCCTSwift/*.swift` and groups public funcs via the editorial `CATEGORIES` array. New OCCTSwift methods that don't match any category are surfaced in the generator's stderr "UNMATCHED" report: extend `CATEGORIES` (add a `markRx` or `nameRx` rule) when something important is missing.

The Node server does not expose the v0.4+ tool surface (selection / remap / annotations / history). Those are Swift-only.
