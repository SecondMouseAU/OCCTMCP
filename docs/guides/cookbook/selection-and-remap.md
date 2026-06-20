---
title: Selection & remap
parent: Cookbook
nav_order: 6
---

# Selection & remap

> **Swift only.** All tools on this page require the Swift `occtmcp-server`. The Node server does not expose them.

This recipe shows the complete lifecycle: pick topology on a body to mint stable `selectionId`s, carry those ids across a mutation via `remap_selection`, and map them onto a mirror copy with `find_correspondences`. At the end, audit and clean up with `list_selections` / `clear_selections`.

`selectionId` format: `sel:<bodyId>#<kind>[<idx>]` — self-describing and parseable.

Reference: [Selection & remap tool reference](../../reference/selection.md).

---

## 1. Pick a face with `select_topology`

[`select_topology`](../../reference/selection.md#select_topology) filters by surface type, area, or normal direction and registers the result in the server's `SelectionRegistry`.

```json
{
  "bodyId": "bracket",
  "kind": "face",
  "filter": {
    "surfaceType": "plane",
    "normalDirection": [0, 0, 1],
    "normalTolerance": 5.0
  },
  "limit": 1
}
```

```json
{
  "selections": [
    {
      "selectionId": "sel:bracket#face[2]",
      "kind": "face",
      "index": 2,
      "centroid": [0.0, 0.0, 10.0],
      "surfaceType": "plane"
    }
  ]
}
```

Save `sel:bracket#face[2]` — this is your stable handle for that face.

---

## 2. Bulk-pick holes with `select_by_feature`

[`select_by_feature`](../../reference/selection.md#select_by_feature) runs AAG feature recognition and mints one `selectionId` per detected feature, skipping the need for a separate `query_topology` call.

```json
{
  "bodyId": "bracket",
  "kinds": ["hole"]
}
```

```json
{
  "selections": [
    { "selectionId": "sel:bracket#face[4]", "featureKind": "hole" },
    { "selectionId": "sel:bracket#face[7]", "featureKind": "hole" }
  ]
}
```

You now have three registered picks on `bracket`. Pass any of these to `add_dimension` or `remap_selection`.

---

## 3. Mutate the body — apply a fillet

Apply a fillet to the top face's bounding edges using [`apply_feature`](../../reference/construction.md#apply_feature). The body is mutated in place.

```json
{
  "bodyId": "bracket",
  "spec": {
    "kind": "fillet",
    "selectionId": "sel:bracket#face[2]",
    "radius": 2.0
  }
}
```

```json
{
  "bodyId": "bracket",
  "faceCount": 14,
  "edgeCount": 21
}
```

The face index `[2]` may have shifted. Use `remap_selection` next.

---

## 4. Carry the pick forward with `remap_selection`

[`remap_selection`](../../reference/selection.md#remap_selection) resolves each id against the post-mutation body. For `apply_feature`, `transform_body`, `heal_shape`, and `boolean_op` the resolution is **history-backed** — exact, with `confidenceMm: 0`. For other mutations it falls back to a closest-centroid heuristic and reports `fate: "approximate"`.

```json
{
  "selectionIds": [
    "sel:bracket#face[2]",
    "sel:bracket#face[4]",
    "sel:bracket#face[7]"
  ]
}
```

```json
{
  "remapped": [
    {
      "input": "sel:bracket#face[2]",
      "outputs": ["sel:bracket#face[2]"],
      "fate": "preserved",
      "confidenceMm": 0.0
    },
    {
      "input": "sel:bracket#face[4]",
      "outputs": ["sel:bracket#face[5]"],
      "fate": "preserved",
      "confidenceMm": 0.0
    },
    {
      "input": "sel:bracket#face[7]",
      "outputs": ["sel:bracket#face[8]"],
      "fate": "preserved",
      "confidenceMm": 0.0
    }
  ]
}
```

**`fate` values:**

| fate | meaning |
|------|---------|
| `"preserved"` | History confirms an exact match (zero distance). |
| `"approximate"` | Centroid heuristic matched within tolerance. |
| `"lost"` | No post-mutation entity within tolerance; the face was consumed. |

When `fate` is `"lost"`, `outputs` is empty — discard the id or re-pick.

---

## 5. Map picks onto a mirror copy with `find_correspondences`

After [`mirror_or_pattern`](../../reference/construction.md#mirror_or_pattern) creates `bracket_mirror`, use [`find_correspondences`](../../reference/selection.md#find_correspondences) to map source picks onto the mirrored body. This is a **cross-body** operation; `remap_selection` only handles the within-body case.

```json
{
  "sourceSelectionIds": [
    "sel:bracket#face[2]",
    "sel:bracket#face[5]"
  ],
  "targetBodyId": "bracket_mirror",
  "transform": {
    "kind": "mirror",
    "planeOrigin": [0, 0, 0],
    "planeNormal": [1, 0, 0]
  }
}
```

```json
{
  "transformSource": "explicit",
  "correspondences": [
    {
      "source": "sel:bracket#face[2]",
      "target": "sel:bracket_mirror#face[2]",
      "confidenceMm": 0.0,
      "fate": "matched"
    },
    {
      "source": "sel:bracket#face[5]",
      "target": "sel:bracket_mirror#face[6]",
      "confidenceMm": 0.0,
      "fate": "matched"
    }
  ]
}
```

When `transform` is omitted, the tool falls back to provenance metadata written by `mirror_or_pattern` (stored in `provenance.json`), then to bbox-translation inference. The `transformSource` field tells you which path resolved (`"explicit"` | `"provenance"` | `"bbox-inference"` | `"identity-fallback"`).

> **Linear / circular patterns** produce N copies and do not write provenance. For those, either supply an explicit `transform` or rely on `"bbox-inference"`.

---

## 6. Audit the registry with `list_selections`

[`list_selections`](../../reference/selection.md#list_selections) returns every active pick — useful when the session context has scrolled away.

```json
{}
```

```json
{
  "selections": [
    {
      "selectionId": "sel:bracket#face[2]",
      "bodyId": "bracket",
      "kind": "face",
      "index": 2,
      "centroid": [0.0, 0.0, 10.0]
    },
    {
      "selectionId": "sel:bracket#face[5]",
      "bodyId": "bracket",
      "kind": "face",
      "index": 5,
      "centroid": [15.0, 0.0, 5.0]
    }
  ]
}
```

---

## 7. Clean up with `clear_selections`

[`clear_selections`](../../reference/selection.md#clear_selections) drops all ids from the registry. Any string you retained after this call is invalid.

```json
{}
```

```json
{ "cleared": 2 }
```

---

## Summary

| step | tool | note |
|------|------|------|
| Pick one face | [`select_topology`](../../reference/selection.md#select_topology) | filter by `surfaceType`, `normalDirection`, `limit` |
| Bulk-pick features | [`select_by_feature`](../../reference/selection.md#select_by_feature) | holes / pockets in one call |
| Mutate body | e.g. `apply_feature` | selectionIds may shift |
| Carry across mutation | [`remap_selection`](../../reference/selection.md#remap_selection) | history-backed for transform / heal / boolean / apply_feature |
| Map onto mirror/pattern copy | [`find_correspondences`](../../reference/selection.md#find_correspondences) | cross-body; `transform` optional |
| Audit | [`list_selections`](../../reference/selection.md#list_selections) | see all live picks |
| Clean up | [`clear_selections`](../../reference/selection.md#clear_selections) | invalidates all existing ids |
