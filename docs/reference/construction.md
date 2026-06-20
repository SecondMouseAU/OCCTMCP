---
title: Construction
parent: Tool Reference
nav_order: 4
---

# Construction

These tools mutate scene bodies by applying features, spatial transforms, boolean set operations, and mirror/pattern operations. Reach for them when you need to modify existing geometry rather than author it from scratch — feature application and booleans both record topology history so [`remap_selection`](selection.md#remap_selection) can carry `selectionId`s across the mutation.

## Tools

- [`apply_feature`](#apply_feature) · [`transform_body`](#transform_body) · [`boolean_op`](#boolean_op) · [`mirror_or_pattern`](#mirror_or_pattern)

---

## `apply_feature`

Apply a single parametric feature (drill, fillet, chamfer, extrude, revolve, thread, or boolean) to a scene body via OCCTSwift's `FeatureReconstructor`.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | ID of the target body in the scene. |
| `feature` | object | yes | FeatureSpec object with a `kind` discriminator. See OCCTSwift/Sources/OCCTSwift/FeatureReconstructor.swift for the schema. |
| `outputBodyId` | string | no | If provided, the result is added as a new body under this ID; otherwise the source body is replaced in place. |

**Returns** — Updated scene manifest. On failure, returns an error string describing what the feature reconstructor rejected.

**Example**

```json
// tool call arguments — fillet the edges of "block" with radius 2 mm
{
  "bodyId": "block",
  "feature": {
    "kind": "fillet",
    "radius": 2.0,
    "edgeSelectionIds": ["sel:block#edge[0]", "sel:block#edge[3]"]
  },
  "outputBodyId": "block_filleted"
}
```
```json
// example result
{
  "bodies": [
    { "id": "block", "name": "Block" },
    { "id": "block_filleted", "name": "Block (filleted)" }
  ]
}
```

**Notes** — The `kind` field is the discriminator for the FeatureSpec union: `drill` / `fillet` / `chamfer` / `extrude` / `revolve` / `thread` / `boolean`. Each kind carries its own required sub-fields (e.g. `fillet` needs `radius`; `drill` needs `axisOrigin`, `axisDirection`, `diameter`, `depth`). `apply_feature` records per-feature topology history (via `BuildResult.histories[id]`) so [`remap_selection`](selection.md#remap_selection) can map `selectionId`s from the input body onto the output.

**Drives** — `OCCTSwift.FeatureReconstructor`; `occtkit reconstruct` (Node).

---

## `transform_body`

Apply translate, rotate, and/or uniform scale to a scene body.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | ID of the body to transform. |
| `translate` | number[3] | no | Translation vector `[dx, dy, dz]` in mm. |
| `rotateAxisAngle` | number[4] | no | Axis-angle rotation `[axisX, axisY, axisZ, radians]`. |
| `rotateEulerXyz` | number[3] | no | Euler rotation `[rx, ry, rz]` in radians applied X→Y→Z. |
| `scale` | number | no | Uniform scale factor. |
| `inPlace` | boolean | no | If true, replaces the body in place (default behaviour when `outputBodyId` is omitted). |
| `outputBodyId` | string | no | If provided, the transformed result is added as a new body; the original is kept. |

**Returns** — Updated scene manifest reflecting the moved/scaled body.

**Example**

```json
// tool call arguments — move "bracket" 50 mm along Z and rotate 90° around Z
{
  "bodyId": "bracket",
  "translate": [0, 0, 50],
  "rotateAxisAngle": [0, 0, 1, 1.5708],
  "outputBodyId": "bracket_placed"
}
```
```json
// example result
{
  "bodies": [
    { "id": "bracket", "name": "Bracket" },
    { "id": "bracket_placed", "name": "Bracket (placed)" }
  ]
}
```

**Notes** — Multiple transform parameters may be combined in a single call; they are composed in the order translate → rotateAxisAngle → rotateEulerXyz → scale. `transform_body` is a rigid/similarity transform and preserves topology 1-to-1, so [`remap_selection`](selection.md#remap_selection) resolves any `selectionId` on the original via the implicit identity path (no history record is written).

**Drives** — `OCCTSwift.Shape.transformed`; `occtkit transform` (Node).

---

## `boolean_op`

Boolean set operation (union / subtract / intersect / split) between two scene bodies. The result is always added as a new body.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `op` | string | yes | Operation: `"union"`, `"subtract"`, `"intersect"`, or `"split"`. |
| `aBodyId` | string | yes | ID of the first (base) body. |
| `bBodyId` | string | yes | ID of the second (tool) body. |
| `outputBodyId` | string | no | ID for the result body. Defaults to a generated name if omitted. |
| `removeInputs` | boolean | no | If true, removes `aBodyId` and `bBodyId` from the scene after the operation. |

**Returns** — Updated scene manifest. Errors from OCCT (non-manifold inputs, no intersection, etc.) are returned as an error string.

**Example**

```json
// tool call arguments — subtract a hole body from a plate
{
  "op": "subtract",
  "aBodyId": "plate",
  "bBodyId": "hole",
  "outputBodyId": "plate_drilled",
  "removeInputs": true
}
```
```json
// example result
{
  "bodies": [
    { "id": "plate_drilled", "name": "plate_drilled" }
  ]
}
```

**Notes** — `boolean_op` records full per-input topology history (via OCCTSwift `*WithFullHistory` variants) under the output body and both inputs. This means [`remap_selection`](selection.md#remap_selection) can map a `selectionId` that lived on either `aBodyId` or `bBodyId` onto the result body.

**Drives** — `OCCTSwift.Shape` boolean operators (`+`, `-`, `&`, `split`); `occtkit boolean` (Node).

---

## `mirror_or_pattern`

Mirror a body through a plane, or create a linear or circular pattern, producing a single (possibly compound) new body in the scene.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | ID of the source body to mirror or copy. |
| `kind` | string | yes | Pattern type: `"mirror"`, `"linear"`, or `"circular"`. |
| `params` | object | yes | Kind-specific parameters. Mirror: `planeNormal` (required), `planeOrigin` (optional). Linear: `direction`, `spacing`, `count`. Circular: `axisOrigin`, `axisDirection`, `totalCount`, `totalAngle` (optional). |
| `outputBodyId` | string | no | ID for the result body. |

**Returns** — Updated scene manifest with the new pattern body added. For mirrors, the mirror plane is written to `provenance.json` in the output directory so [`find_correspondences`](selection.md#find_correspondences) can recover the transform automatically.

**Example**

```json
// tool call arguments — mirror "fin" through the XZ plane (Y=0)
{
  "bodyId": "fin",
  "kind": "mirror",
  "params": {
    "planeNormal": [0, 1, 0],
    "planeOrigin": [0, 0, 0]
  },
  "outputBodyId": "fin_mirrored"
}
```
```json
// example result
{
  "bodies": [
    { "id": "fin", "name": "Fin" },
    { "id": "fin_mirrored", "name": "fin_mirrored" }
  ]
}
```

**Notes** — `mirror_or_pattern` produces new bodies rather than mutating in place, so [`remap_selection`](selection.md#remap_selection) does not apply across source → copy. Use [`find_correspondences`](selection.md#find_correspondences) instead: for mirrors it reads the provenance transform automatically; for linear/circular patterns supply the instance transform explicitly (provenance is not written for multi-copy patterns).
