---
type: reference
title: History wiring and selectionId remap
resource: https://github.com/SecondMouseAU/OCCTMCP/blob/main/Sources/OCCTMCPCore/Tools/RemapTools.swift
tags: [reference, history, remap, graphuid, selection, brepgraph]
description: How a selectionId survives a mutation: the three remap rungs, the per-tool history path, and the identity hazards (instance-scoped UIDs, TShape identity in findNode, enumeration-order labels) that make a remap silently wrong rather than failing.
generated: { by: human:gsdali, at: 2026-09-06 }
sources:
  - { id: occtswift-331, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/331, usage_count: 2 }
usage_window: { from: 2026-07-27, to: 2026-09-07 }
---

# History wiring and selectionId remap

## Layered architecture (post-Tools / AIS split)

OCCTSwift / OCCTSwiftViewport are kernel layers. `OCCTSwiftTools` is the bridge (Shape ↔ ViewportBody, plus Curve / Surface / Wire / **Point** converters). `OCCTSwiftAIS` is the interactive-services layer (selection, manipulators, dimensions). `render_preview` depends on **Tools + Viewport**. The whole cohort is now aligned at v1.0.x: Tools / AIS / Scripts v1.0 graduated their Viewport floors to 1.0.x, so the v0.10–v1.1 hold at Viewport 0.55.x is gone.

## History wiring (selectionId remap across mutations)

`select_topology` resolves through `HistoryRegistry.currentInput(bodyId:path:)` rather than a
disposable per-call graph. This establishes (or reuses) the SAME retained graph a later
history-aware mutation will absorb into, and mints a `BRepGraph.GraphUID` per anchor, attached
directly to the `TopologyAnchor` passed to `SelectionRegistry.record(anchor:snapshot:)` (#182: a
field on the anchor itself, not a side-table keyed by selectionId the way it worked before; see
the `SelectionRegistry.swift` bullet above for the full re-key writeup). Still not a field on
`AnchorSnapshot`, which is `Encodable` straight into LLM-facing responses and has no business
carrying an opaque uid.

`remap_selection` resolves a `selectionId` against the post-mutation state of a body via three
rungs, most-preferred first:

1. **GraphUID** (#93): `registry.graphUID(for: id)` then `historyRegistry.graph(for: bodyId).node(forUID:)`,
   then the same `findDerivedOrSelf` walk as rung 2. Preferred because a UID survives index
   renumbering within the graph across multiple hops, unlike a selectionId's embedded literal
   index. Falls through to rung 2 if the UID doesn't resolve (e.g. it was minted from a
   disposable graph, or by a call site that doesn't mint UIDs yet).
2. **Recorded history graph, anchor's embedded index**: `HistoryRegistry.graph(for: bodyId)` then
   `BRepGraph.findDerivedOrSelf(of:)`:
   - Non-empty derivatives: fate in {preserved, split}, confidenceMm = 0.
   - Empty result: explicitly recorded as deleted, fate = lost.
   - `[self]` (no record at all): preserved at same index, confidenceMm = 0. This is also what a
     **generation reset** looks like from the outside; a fresh graph with zero history records
     resolves every node to `[self]` unconditionally, which is indistinguishable from genuine
     "untouched" through this API alone (see the `HistoryRegistry.swift` bullet above).
3. **Centroid heuristic** (unchanged, last resort): load pre and post BREPs, find nearest
   face/edge/vertex within an epsilon. fate is preserved if within ε, lost otherwise.
   confidenceMm reports the centroid distance.

After any rung-1/rung-2 (history-based) remap, `RemapTools.refreshAfterHistoryRemap` re-mints a
fresh GraphUID for the new anchor **from the retained lineage graph only**, never from the
disposable `currentGraph` rung 3 uses, so a multi-hop remap chain stays UID-exact instead of
degrading to rung 2 (or rung 3) after one hop.

Per-tool history path, via `HistoryRegistry.currentInput`/`commit`/`absorb`:

| Tool             | History path                              | Notes |
|------------------|-------------------------------------------|-------|
| `transform_body` | generation reset (`commit(ref: nil)`)     | no `*WithFullHistory` variant wired in yet: OCCTSwift#331 (shipped v1.14.0) added `translated`/`rotated`/`scaled`/`mirrored`/pattern `*WithFullHistory` upstream, but OCCTMCP hasn't switched this call site over |
| `heal_shape`     | real history via `healedWithFullHistory()` (OCCTSwift v1.13.0/#327) | falls back to plain `healed()` + generation reset if the `*WithFullHistory` variant returns nil, or its absorb doesn't grow `historyRecordCount` |
| `boolean_op`     | per-input history via `HistoryRegistry.recordBooleanHistory` | two independent graphs (NodeRefs/GraphUIDs are graph-scoped): a-side's graph becomes `outId`'s canonical graph too (`commit`, writes an entry); b-side only needs `absorb` (no entry write; `bBodyId`'s own file is unchanged, so writing one would overwrite its liveShape/fingerprint with the OTHER side's output) |
| `apply_feature`  | per-feature history via `commit`, chained via `absorb` if `result.histories` has >1 entry | absorbs ONCE per graph object regardless of in-place vs new-`outputBodyId`: the source body's own entry (when different from the mutated one) shares the SAME graph object reference (`BRepGraph` is a reference type) and sees the absorbed history for free, no second write |
| `mirror_or_pattern` | generation reset for the output body only; source body's entry untouched | same #331 gap as `transform_body`; source's file didn't change so its lineage stays as-is |

`mirror_or_pattern` also doesn't fit `remap_selection`'s contract (it produces new bodies rather than mutating in place). For that case use `find_correspondences`, which takes a source body and target body and applies a transform to each source anchor's centroid before nearest-neighbour search on the target. Pure geometry, no OCCT history involved: pattern instances aren't OCCT-derivatives of the source.

**Persistence caveat:** `BRepGraph.GraphUID` is `Codable` but **instance-scoped**: it does not
survive `GraphSnapshot` restore or a process restart (a rebuild mints a new `instanceID`; re-mint
from `(kind, index)` after reloading). A retained graph's `snapshot()` also serializes the
*pre-mutation* `sourceBREP` captured at construction, not updated by later `add()` calls.

**`findNode(for:)` nil behaviour:** every UID-minting path above (`SelectionTools.graphIndex`,
called before `TopologyAnchor`'s `uid:` argument is resolved via `graph.uid(ofNodeKind:index:)`;
`HistoryRegistry.trackableRoot`; `ReconstructRegistry.resolveUID`) first calls
`BRepGraph.findNode(for:)` to locate a
`Shape` within the graph, and it matches by `TShape` object identity, not geometric equality. A
`Shape` that is genuinely a sub-shape of the graph's own source (via `.faces()`/`.edges()`/
`subShapes(ofType:)` on that exact `Shape` instance) always resolves. A `Shape` that was
independently **re-derived** (rebuilt from fitted surface parameters, reconstructed from a mesh,
or loaded from a separate BREP round-trip of geometrically identical content), returns `nil` even
when it occupies the same location, because it has a different `TShape` tree. `graphIndex(...)`
(`SelectionTools.swift`) and `trackableRoot(for:in:)` (`HistoryRegistry.swift`) both treat this as
an expected, non-error outcome and fall back accordingly (documented at each call site); a caller
minting a UID for reconstruction-fitted geometry needs to resolve against the graph's OWN face
Shape (e.g. `graph.shape(nodeKind:nodeIndex:)`), not a freshly-fitted one, or the lookup will
silently miss.

**#95/#92 (`ReconstructRegistry`):** the pre-#95 invariant comment on `ReconstructRegistry.sessions`
flagged that `<kind>:<index>` wire strings would silently misattribute if a session graph were ever
compacted/deduped while live (#92); nothing does that today (`graph_compact`/`graph_dedup` are
one-shot and file-path-only), but the risk was real if a future `reconstruct_*` tool wired one in.
#95 switches BOTH node resolution AND attribute storage to `GraphUID`: `resolveUID(id:nodeStr:in:)`
mints and caches a UID for a wire string on first resolution, re-resolving through that UID (not
the string's embedded index) on every later call; `attrStore` (a private `[sessionId: [GraphUID:
[key: AttrValue]]]`, replacing direct reads/writes on `graph.attributes`) keys every `reconstruct.*`
attribute by that SAME UID. Because a `GraphUID` never encodes an index, an attribute set before a
hypothetical `compact()` keeps applying to the same node after one: there is no pre/post-compaction
NodeRef to migrate between, unlike the OCCTSwift `NodeAttributeStore` this used to write through
directly. `makeSnapshot(id:)` / `store(id:graph:)` convert to/from the NodeRef-keyed
`GraphSnapshot` wire format (the only one `BRepGraph.snapshot()` / `BRepGraph(snapshot:)`
understand) at the persistence boundary only. Verified against a real `compact()` renumbering,
including that attributes set both before and after the renumbering land on the same entity
(`ReconstructToolsTests.resolveSurvivesCompaction`). This closes #92 in full: no residual gap
remains for a future tool wiring `compact()`/`deduplicate()` into a live session to work around.

**Cross-referencing hazard:** `query_topology` / `check_thickness` emit informational
`face[i]`/`edge[i]` labels in `Shape.faces()`/`.edges()` **enumeration order**, not `BRepGraph`
node-index order: the same divergence `TopologyIdentityTests` proves for edges/vertices. Don't
feed those labels' indices into a `selectionId` by hand; they're a different index space.

`find_correspondences`'s `transform` is optional. Resolution order:
1. **Explicit hint**: `translate` / `mirror` / `rotate` / `compound { steps: [...] }` (the last one is a recursive composition applied in array order). Codable, so the same JSON shape works in tool args and on disk.
2. **`<output_dir>/provenance.json`**: `mirror_or_pattern` writes its mirror plane here for every output body it produces. (Linear / circular patterns produce N copies, which don't fit the single-target return shape, so they're skipped.)
3. **Bbox-translation inference**: if source and target bbox sizes match, transform is the centroid delta. Catch-all for `execute_script`-built duplicates that didn't record anything.

The response includes `transformSource ∈ {explicit, provenance, bbox-inference, identity-fallback}` so callers can tell which path resolved.
