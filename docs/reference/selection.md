---
title: Selection & remap
parent: Tool Reference
nav_order: 6
---

# Selection & remap

These tools let an LLM pick faces, edges, or vertices on scene bodies and carry those picks forward
across mutations, transforms, and pattern instances. All eight tools are **Swift only**: the Node
server does not expose them.

`get_selection`/`highlight_selection` (#189/#190) are a distinct pair within this family: instead of
picking topology in this server's own scene, they bridge to a *live viewport host* process (e.g.
ACADStudio) reading/writing sidecar files in the resolved output directory, per the wire format in
[`SecondMouseAU/OCCTSwiftInteraction#17`](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/17).
No host implements the writer/watcher side yet as of this writing; both tools are host-agnostic by
construction and degrade to an explicit `noHost`/`timeout` result rather than hanging when nothing is
listening.

## Tools

- [`select_topology`](#select_topology) · [`remap_selection`](#remap_selection) · [`find_correspondences`](#find_correspondences) · [`select_by_feature`](#select_by_feature) · [`list_selections`](#list_selections) · [`clear_selections`](#clear_selections) · [`get_selection`](#get_selection) · [`highlight_selection`](#highlight_selection)

---

## `select_topology`

Pick faces, edges, or vertices on a scene body matching optional filter criteria. Mints and
registers server-tracked `selectionId`s in the format `sel:<bodyId>#<kind>[<idx>]`.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to select topology on. |
| `kind` | string (`"body"` \| `"face"` \| `"edge"` \| `"vertex"`) | yes | Topological entity type to select. |
| `filter` | object | no | face: `surfaceType`, `minArea`, `maxArea`, `normalDirection`, `normalTolerance`. edge: `curveType`, `minLength`, `maxLength`. |
| `limit` | integer (≥ 1) | no | Maximum number of entities to return. |

**Returns:** Array of `selectionId` strings plus an anchor snapshot (centroid, kind, index) for
each matched entity. The registry retains these until `clear_selections` is called or the session
ends. Edge anchors (#119) also carry `endpoints` (`[start, end]`, every edge kind) plus a unit
`direction` for LINE edges, and `circleCenter`/`radius`/`axis`/`startAngle`/`endAngle` (radians,
measured from the circle's own xAxis) for CIRCULAR edges.

**Example**

```json
// tool call arguments
{ "bodyId": "part", "kind": "face", "filter": { "surfaceType": "plane", "normalDirection": [0, 0, 1], "normalTolerance": 5.0 }, "limit": 1 }
```
```json
// example result
{
  "selections": [
    {
      "selectionId": "sel:part#face[2]",
      "kind": "face",
      "index": 2,
      "centroid": [0.0, 0.0, 10.0],
      "surfaceType": "plane"
    }
  ]
}
```

**Notes:** `selectionId`s produced here can be passed directly to `add_dimension`,
`remap_selection`, and `find_correspondences`. Use `list_selections` to review all live picks.

---

## `remap_selection`

Remap one or more `selectionId`s to their post-mutation equivalents on the same body. Uses
history-backed resolution (exact, zero-distance) for tools that record topology history
(`transform_body`, `heal_shape`, `boolean_op`, `apply_feature`); falls back to a
closest-centroid heuristic for all other mutations. `heal_shape` resolves via real per-subshape
history (OCCTSwift v1.13.0) rather than a topology-count heuristic. `select_topology` mints a
durable GraphUID per pick in addition to its `selectionId`; `remap_selection` tries that GraphUID
first, then the recorded history graph, then the centroid heuristic.

A body mutated twice in a row by history-bearing tools (e.g. `apply_feature` called twice)
correctly chains the connecting history across both mutations; the second mutation absorbs into
the same retained graph as the first, not a fresh disposable one.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `selectionIds` | string[] | yes | One or more `selectionId`s to remap. |
| `toleranceMmFraction` | number | no | Fraction of body bbox diagonal to use as the match tolerance. Default `0.01`. |

**Returns:** For each input `selectionId`: zero or more new `selectionId`s plus a `fate` string
(`"preserved"` \| `"approximate"` \| `"lost"`). Fate is `"preserved"` when history confirms an
exact match, `"approximate"` for centroid-heuristic matches, `"lost"` when no post-mutation
entity falls within the tolerance.

**Example**

```json
// tool call arguments
{ "selectionIds": ["sel:part#face[2]"] }
```
```json
// example result
{
  "remapped": [
    {
      "input": "sel:part#face[2]",
      "outputs": ["sel:part#face[2]"],
      "fate": "preserved",
      "confidenceMm": 0.0
    }
  ]
}
```

**Notes:** This tool handles the *within-body* case only. To carry a pick from a source body
onto a mirrored or patterned copy, use `find_correspondences`.

---

## `find_correspondences`

Map `selectionId`s from a source body onto a target body that is a known transform of the source
(typically a `mirror_or_pattern` output). Applies an optional explicit transform to each source
anchor centroid, then nearest-neighbour searches among the target's topology.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `sourceSelectionIds` | string[] | yes | `selectionId`s minted on the source body. |
| `targetBodyId` | string | yes | Body ID of the transformed copy to map onto. |
| `toleranceMmFraction` | number | no | Fraction of target bbox diagonal to use as the match tolerance. Default `0.01`. |
| `transform` | object | no | Transform applied to source anchors before nearest-neighbour search. Exactly one of `translate` / `mirror` / `rotate` / `compound` per object. See sub-fields below. |

**`transform` sub-fields**

| name | type | description |
|------|------|-------------|
| `kind` | string (`"translate"` \| `"mirror"` \| `"rotate"` \| `"compound"`) | Required discriminator. |
| `offset` | number[3] | `translate`: `[dx, dy, dz]`. |
| `planeOrigin` | number[3] | `mirror`: a point on the mirror plane. |
| `planeNormal` | number[3] | `mirror`: plane normal (normalised internally). |
| `axisOrigin` | number[3] | `rotate`: a point on the rotation axis. |
| `axisDirection` | number[3] | `rotate`: axis direction (any length). |
| `angleDeg` | number | `rotate`: angle in degrees, right-hand rule about `axisDirection`. |
| `steps` | object[] | `compound`: array of nested transform objects applied in order. |

**Returns:** For each source `selectionId`: one target `selectionId` (or `null`) plus
`confidenceMm` and `fate` (`"matched"` \| `"lost"`).

When `transform` is omitted, resolution falls back to provenance metadata recorded by
`mirror_or_pattern` (stored in `provenance.json`), then to bbox-translation inference, and
finally to an identity fallback. The response includes a `transformSource` field indicating which
path resolved (`"explicit"` \| `"provenance"` \| `"bbox-inference"` \| `"identity-fallback"`).

The response also includes a `warnings` array. It is populated whenever `transform` is omitted and
`sourceSelectionIds` cannot be correlated to a single source body for the provenance/bbox-inference
fallbacks to run against: the ids span more than one body, the array is empty, or every id fails to
parse as a `selectionId`. In each of those cases both fallbacks are skipped and `transformSource`
reports `"identity-fallback"`.

**Example**

```json
// tool call arguments
{
  "sourceSelectionIds": ["sel:part#face[2]"],
  "targetBodyId": "part_mirror",
  "transform": {
    "kind": "mirror",
    "planeOrigin": [0, 0, 0],
    "planeNormal": [1, 0, 0]
  }
}
```
```json
// example result
{
  "transformSource": "explicit",
  "correspondences": [
    {
      "source": "sel:part#face[2]",
      "target": "sel:part_mirror#face[5]",
      "confidenceMm": 0.0,
      "fate": "matched"
    }
  ]
}
```

**Notes:** For within-body remapping after a mutation, use `remap_selection` instead. Linear and
circular pattern outputs produce N copies; provenance is not written for them, so supply an
explicit `transform` or rely on bbox-translation inference.

---

## `select_by_feature`

Run AAG feature recognition on a body and register a `selectionId` for each detected hole or
pocket, without requiring a prior `query_topology` call.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to recognise features on. |
| `kinds` | Array of `"pocket"` \| `"hole"` | no | Feature kinds to detect. Defaults to both when omitted. |

**Returns:** Array of `selectionId`s (one per detected feature instance) plus metadata
(kind, representative face indices). The picks are registered in the `SelectionRegistry` and
can be forwarded directly to `add_dimension`.

**Example**

```json
// tool call arguments
{ "bodyId": "bracket", "kinds": ["hole"] }
```
```json
// example result
{
  "selections": [
    { "selectionId": "sel:bracket#face[4]", "featureKind": "hole" },
    { "selectionId": "sel:bracket#face[7]", "featureKind": "hole" }
  ]
}
```

**Drives:** AAG feature recognition (same engine as `recognize_features`).

---

## `list_selections`

Return every active `selectionId` held in the `SelectionRegistry` together with its anchor
metadata. A cheap introspection call, useful when the session context no longer holds the
original pick results.

Scoped to anchor-based selections (`select_topology`, `select_by_feature`, `remap_selection`,
`find_correspondences`) — `pick_surface_point` results have no `TopologyAnchor` (a free surface
point isn't a face/edge/vertex pick) and don't appear here, even though they're live in the
registry. See `clear_selections` below: its `cleared` count does include them.

**Server:** Swift only

No parameters.

**Returns:** Array of entries, each with `selectionId`, `bodyId`, `kind`, `index`, and
`centroid`. Returns an empty array when the registry is clear.

**Example**

```json
// tool call arguments
{}
```
```json
// example result
{
  "selections": [
    {
      "selectionId": "sel:part#face[2]",
      "bodyId": "part",
      "kind": "face",
      "index": 2,
      "centroid": [0.0, 0.0, 10.0]
    }
  ]
}
```

---

## `clear_selections`

Drop every `selectionId` from the `SelectionRegistry`. Any existing `selectionId` strings
become invalid after this call.

**Server:** Swift only

No parameters.

**Returns:** `{ "cleared": <count> }`: the number of entries removed, counting both anchor-based
selections and point-snapshot-only picks (`pick_surface_point`) — everything `clear()` actually
discards, not just the anchor-scoped subset `list_selections` enumerates ([#150](https://github.com/SecondMouseAU/OCCTMCP/issues/150)).

**Example**

```json
// tool call arguments
{}
```
```json
// example result
{ "cleared": 3 }
```

---

## `get_selection`

Read a live viewport host's current selection from `<output_dir>/selection.json` + `host.lock`, per
the wire format in `SecondMouseAU/OCCTSwiftInteraction#17`.

**Server:** Swift only

No parameters.

**Returns:** A three-state result: `state: "noHost"` (`selections: null` — no viewport host is
running at all) vs `state: "hostRunning"` with `selections: []` (host live, nothing picked) or
`selections: [...]` (host live, N items picked). Never collapses those into one boolean/empty-array
reading. Each resolved selection carries `selectionId`, `bodyId`, `kind`, `index`, the host's own
`uid` (passed through as-is), an `anchor` snapshot (area/bounds/centroid for a face, length/curveType/
endpoints for an edge, position for a vertex — resolved the same way `select_topology` resolves a
match), or an `error` string when that one entry couldn't be resolved (bad `bodyId`, out-of-range
`index`) without failing the rest of the response. A host that's running but whose `selection.json` is
missing or malformed (a torn read) is reported as an explicit tool error, never swallowed into an
empty selection list.

**Example**

```json
// tool call arguments
{}
```
```json
// example result
{
  "state": "hostRunning",
  "revision": 4,
  "updatedAt": "2026-08-21T00:00:00Z",
  "selections": [
    {
      "selectionId": "sel:part#face[2]",
      "bodyId": "part",
      "kind": "face",
      "index": 2,
      "uid": "host-graphuid-string",
      "anchor": { "center": [0.0, 0.0, 10.0], "area": 314.15, "surfaceType": "plane" },
      "error": null
    }
  ]
}
```

**Notes:** The resulting `selectionId`s compose with `remap_selection`/`find_correspondences`/
`add_dimension`/`measure_distance` exactly like ones `select_topology` minted itself. The host's
`uid` is an opaque string from its own process-local `BRepGraph.GraphUID` and is never treated as a
uid this server's own registry could resolve.

---

## `highlight_selection`

Ask a live viewport host to highlight one sub-shape, by writing
`<output_dir>/highlight_requests/<id>.json` and polling
`<output_dir>/highlight_requests/handled/<id>.json` for the host's real outcome.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body the highlighted sub-shape belongs to. |
| `kind` | string (`"body"` \| `"face"` \| `"edge"` \| `"vertex"`) | yes | Topological entity type. |
| `index` | integer | yes | Entity index (host-scoped; not validated against this server's own scene). |
| `scheme` | string (`"replace"` \| `"add"` \| `"remove"` \| `"xor"`) | yes | Mirrors `OCCTSwiftAIS.SelectionScheme` exactly. |
| `question` | string | no | Optional natural-language context for the host to show alongside the highlight. |
| `timeoutSeconds` | number | no | How long to poll `handled/<id>.json` before returning `outcome: "timeout"`. Default `5.0`. |

**Returns:** `{ "id": <string or null>, "outcome": <string>, "reason": <string or null> }`. `outcome`
is the host's own `"applied"`/`"rejected"`/`"superseded"` (read from its `handled/<id>.json`), or
`"timeout"` if nothing answers within the deadline, or `"noHost"` (with `id: null`, no request
written) if no viewport host is running at all.

**Example**

```json
// tool call arguments
{ "bodyId": "part", "kind": "face", "index": 2, "scheme": "replace" }
```
```json
// example result
{ "id": "3f9b1c2a-...", "outcome": "applied", "reason": null }
```

**Notes:** `kind`/`scheme` are validated against their closed wire-format enums before anything is
written; a malformed request is never written. `bodyId`/`index` are written through UNVALIDATED
against the live scene (this tool has no other access to check them) — a bad reference still writes
the request and comes back as the host's own `rejected` outcome through the same poll, not a
client-side pre-check. `id` is generated by this tool, never supplied by the caller.
