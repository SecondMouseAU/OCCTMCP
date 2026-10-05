---
title: WebAssembly core
nav_order: 6
---

# WebAssembly core (plan and tool classification)

Status: plan only. Nothing in this document has been built or run. The measurements below are
read off source, not off a wasm build, and each one says what would confirm it.

## Why

The Swift server needs macOS 15+ because `OCCT.xcframework` is Apple-only. A Linux cloud session
cannot run it, and rendering to pixels is not an acceptable substitute for the numeric tools. OCCTSwift
now builds for `wasm32-unknown-wasip1` (see OCCTSwift `docs/wasm-feasibility.md` and
`docs/guides/wasm-consumer-setup.md`), so the geometry can run anywhere WASI runs.

## The seam is `occtkit`

The Node server already delegates every geometry call to an `occtkit` verb through
`resolveOcctkit()` (`src/occtkit.ts`), either one-shot (`execFile`) or through the long-lived
`occtkit <verb> --serve` JSONL loop (`src/occtkit-serve.ts`). Replacing the `occtkit` binary with a
WASI build of the same verbs changes one function in this repo, not 37 tool handlers.

Of the 29 files under `OCCTSwiftScripts/Sources/occtkit/Commands/`, by their imports:

| Needs | Verbs |
|---|---|
| OCCTSwift + ScriptHarness only | analyze-clearance, boolean, check-thickness, compose-sheet-metal, dxf-export, feature-recognize, graph-compact, graph-dedup, graph-query, graph-select, graph-validate, heal, import, inspect-assembly, load-brep, measure-deviation, measure-distance, mesh, metrics, pattern, query-topology, reconstruct, set-metadata, transform |
| + DrawingComposer (OCCTSwift only) | drawing-export |
| + OCCTSwiftMesh (OCCTSwift only) | simplify-mesh |
| + OCCTSwiftIO (heavy mesh IO stack, unchecked for wasm) | graph-ml |
| + OCCTSwiftViewport, OCCTSwiftTools, OCCTSwiftAIS (Metal, SwiftUI) | render-preview |
| Spawns `swift build` | run |

So a `wasm` occtkit is the `occtkit` target minus `render-preview` and `run`, with `graph-ml`
conditional on OCCTSwiftIO. The verb targets (`GraphValidate`, `GraphCompact`, ...) already depend on
OCCTSwift alone.

## Work, in order

1. **OCCTSwiftScripts**: add a `OCCTSWIFT_WASI` branch to `Package.swift` (the same switch OCCTSwift
   uses), an `occtkit-wasm` executable target over the verbs above, and move the `occtkit` entry code
   to `FoundationEssentials` and the explicit libc import (otherwise the module grows by about 10 MB
   brotli). `--serve` reads stdin and writes stdout, which WASI provides.
2. **This repo**: a third branch in `resolveOcctkit()` that runs `occtkit.wasm` through `node:wasi`
   with the output directory preopened, selected by `OCCTMCP_OCCTKIT_WASM=<path>`. Native `occtkit`
   stays the default.
3. **Parity**: run each verb natively and on wasm over the same BREPs and diff the JSON, as
   valvegear's `cad/wasm/parity.sh` does. OCCTSwift records at least one known behaviour difference
   (`gp_Dir` zero-norm validation does not raise on wasm, OCCTSwift#2891), so parity is a gate, not
   an assumption.
4. **Swift server (separate, later)**: the 42 Swift-only tools need the Viewport types split out of
   the Metal target, the MCP Swift SDK's swift-nio transport replaced, and OCCTSwiftIO gated. Not
   needed for the Node route.

## Tool classification for the Swift server (79 tools)

Heuristic: for each case in `Server.dispatch`, the handler file's imports. A comment that merely
mentions a type is counted, so treat the Viewport columns as an upper bound.

| Class | Count | Tools |
|---|---|---|
| Pure OCCTSwift, no Viewport | 63 | everything not listed below, including selection, remap, topology and metrics, graph, construction, mesh diagnostics, thickness, deviation, reconstruct, assembly, drawing, I/O |
| Builds `ViewportBody` values for output (needs the type, not the GPU) | 11 | remove_body, clear_scene, rename_body, set_appearance, compare_versions, align_bodies, segment_mesh_zones, zone_continuity_sweep, mesh_curvature, detect_mesh_features, fit_primitives |
| Needs a renderer or the viewport ray pick | 4 | render_preview, signed_deviation_heatmap, overlay_render, pick_surface_point |
| Spawns a process | 1 | execute_script |

## Known costs

- The wasm module is about 99 MB uncompressed (17 MB brotli), per OCCTSwift's own measurement.
- No release of OCCTSwift carries wasm support yet, so a build pins a branch or revision.
- Building needs the swift.org 6.4.0 toolchain and its wasm SDK, plus a prebuilt 38 MB kernel.
- Per-domain test targets have never been compiled for wasm (OCCTSwift#2793).
