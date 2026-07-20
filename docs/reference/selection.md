---
title: Selection & remap
parent: Tool Reference
nav_order: 6
---

# Selection & remap

These tools let an LLM pick faces, edges, or vertices on scene bodies and carry those picks forward
across mutations, transforms, and pattern instances. All six tools are **Swift only**: the Node
server does not expose them.

## Tools

- [`select_topology`](#select_topology) · [`remap_selection`](#remap_selection) · [`find_correspondences`](#find_correspondences) · [`select_by_feature`](#select_by_feature) · [`list_selections`](#list_selections) · [`clear_selections`](#clear_selections)

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
ends.

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

**Returns:** `{ "cleared": <count> }`: the number of entries removed.

**Example**

```json
// tool call arguments
{}
```
```json
// example result
{ "cleared": 3 }
```
