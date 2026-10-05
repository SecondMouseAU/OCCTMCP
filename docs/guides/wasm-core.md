---
title: WebAssembly core
nav_order: 6
---

# WebAssembly core (plan and tool classification)

Status: working for the Node server. A WASI `occtkit` builds (OCCTSwiftScripts, branch
`claude/wasm-occtkit`) and the Node tools run through it on Linux. Measured results are in
[Measured](#measured). Not done: a native-vs-wasm parity run (needs a Mac) and the Swift server.

## Use it

```bash
# in OCCTSwiftScripts: Scripts/build-wasm.sh  ->  .build/out/Products/Release-webassembly-wasm32/occtkit.wasm
npm run build
OCCTMCP_OCCTKIT_WASM=/path/to/occtkit.wasm node dist/index.js
```

`OCCTMCP_OCCTKIT_WASM` wins over an `occtkit` on `$PATH`. The module runs under Node's `node:wasi`
through `dist/wasi-run.js`, which preopens the scene output directory, the temp directory, the
current directory and any in `OCCTMCP_WASI_PREOPEN` at their host paths, because WASI has no working
directory and the tools pass absolute paths. Tools whose verb is not in the WASI build
(`execute_script`, `render_preview`, `graph_ml`, `simplify_mesh`, `--serve`) return the verb's
"Unknown subcommand" error. The unit tests assume the variable is unset (several fake a native
`occtkit`); the integration test `tests/integration/wasm-occtkit.test.mjs` needs it set and skips
itself otherwise.

## Measured

Linux x86_64, swift.org 6.4.0, wasm SDK 6.4.0, wasi-sdk 34.0, Node 22. Two 10 mm cubes offset by 5
in x and y, through the real tool functions (`tests/integration/wasm-occtkit.test.mjs`):

| Tool | Expected | Got |
|---|---|---|
| compute_metrics volume, area | 1000, 600 | 999.9999999999998, 599.9999999999999 |
| compute_metrics centre of mass | (5, 5, 5) | (5, 5, 5) to 1e-15 |
| boolean_op intersect, union, subtract | 250, 1750, 750 | within 1e-13 of each |
| measure_distance apart, overlapping | 10, 0 | 10, 0 |
| check_thickness | 10 | 9.9999 |

Build cost: about 2 minutes cold (OCCTSwift is compiled), about 30 seconds incremental. The module
is 144 MB unoptimised. Each verb call is a fresh process and takes about 0.42 s for a small BREP (three runs, 0.42 to 0.46 s), most of it loading the module.

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

1. **OCCTSwiftScripts** (done, OCCTSwiftScripts#126): an `OCCTSWIFT_WASI` branch in `Package.swift`
   that keeps only OCCTSwift, excludes the sources that need Metal, SQLite3 or processes, and a WASI
   `Registry`. `--serve` is off because its output capture uses `dup2`, which WASI lacks. Still to
   do there: `FoundationEssentials` instead of `Foundation` (about 10 MB brotli, OCCTSwift#2761),
   `simplify-mesh` once OCCTSwiftMesh builds for wasm, and a CI job for the wasm target.
2. **This repo** (done): `OCCTMCP_OCCTKIT_WASM` in `resolveOcctkit()`, `src/wasi-run.ts`,
   `src/wasi-preopens.ts`, unit tests and the integration test above.
3. **Parity** (not done): run each verb natively and on wasm over the same BREPs and diff the JSON,
   as valvegear's `cad/wasm/parity.sh` does. OCCTSwift records at least one known behaviour
   difference (`gp_Dir` zero-norm validation does not raise on wasm, OCCTSwift#2891), so parity is a
   gate, not an assumption. Needs a Mac for the native side.
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

- OCCTSwift measured a small wasm module at about 99 MB uncompressed (17 MB brotli); this one is 144 MB before size work.
- No release of OCCTSwift carries wasm support yet, so a build pins a branch or revision.
- Building needs the swift.org 6.4.0 toolchain and its wasm SDK, plus a prebuilt 38 MB kernel.
- Per-domain test targets have never been compiled for wasm (OCCTSwift#2793).
