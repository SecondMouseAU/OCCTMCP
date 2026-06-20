---
title: Reconstruction graph
parent: Tool Reference
nav_order: 11
---

# Reconstruction graph

All Swift only. The `reconstruct_*` tools give an LLM read/write access to an attributed reconstruction graph: topology is exposed as nodes addressed `<kind>:<index>` (e.g. `face:3`) and per-node `reconstruct.*` attributes track decisions, fit overrides, and instance membership. The fitting engine lives in OCCTReconstruct — `reconstruct_force_fit` records an override as an attribute; it does **not** re-fit.

## Tools

- [`reconstruct_get_graph`](#reconstruct_get_graph) · [`reconstruct_set_decision`](#reconstruct_set_decision) · [`reconstruct_force_fit`](#reconstruct_force_fit) · [`reconstruct_confirm_instances`](#reconstruct_confirm_instances) · [`reconstruct_export_session`](#reconstruct_export_session) · [`reconstruct_import_session`](#reconstruct_import_session)

---

## `reconstruct_get_graph`

Export the attributed reconstruction graph as JSON: topology counts, every annotated node (with its `reconstruct.*` attributes), and instance clusters. Pass `sessionId` to read an existing session, or `bodyId` to start a new one from a scene body.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | no | Scene body to start a new session from (`sessionId` defaults to `bodyId`). |
| `sessionId` | string | no | Existing reconstruction session id. |

**Returns** — JSON object with topology counts, the list of annotated nodes (each with its node address and current `reconstruct.*` attributes), and any instance clusters. Returns an error if neither `bodyId` nor `sessionId` is supplied, or the body/session cannot be found.

**Example**

```json
// tool call arguments — start a new session from a body
{ "bodyId": "scan_part" }
```
```json
// example result
{
  "sessionId": "scan_part",
  "topologyCounts": { "face": 12, "edge": 30, "vertex": 20 },
  "annotatedNodes": [
    { "node": "face:0", "attributes": { "reconstruct.decidedBy": "geometric", "reconstruct.accepted": true } }
  ],
  "instanceClusters": []
}
```

**Notes** — `sessionId` is the handle used by all subsequent `reconstruct_*` calls. When starting from a `bodyId`, the returned `sessionId` is typically the same string as `bodyId` unless overridden.

---

## `reconstruct_set_decision`

Annotate a node's reconstruction decision: `decidedBy` (`geometric` | `ml` | `human`) and/or `accepted` (accept or reject a proposed fit). At least one of the two optional annotation fields must be supplied alongside the required `sessionId` and `node`.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `sessionId` | string | yes | Reconstruction session id. |
| `node` | string | yes | Target node as `<kind>:<index>`, e.g. `face:3`. |
| `decidedBy` | string (`geometric` \| `ml` \| `human`) | no | Who or what made the decision. |
| `accepted` | boolean | no | Whether the proposed fit is accepted. |

**Returns** — Confirmation JSON with the updated node address and the attributes now stored, or an error if the session/node is not found or neither annotation field was supplied.

**Example**

```json
// tool call arguments
{ "sessionId": "scan_part", "node": "face:3", "decidedBy": "human", "accepted": true }
```
```json
// example result
{ "sessionId": "scan_part", "node": "face:3", "updated": { "reconstruct.decidedBy": "human", "reconstruct.accepted": true } }
```

---

## `reconstruct_force_fit`

Override a node's fitted surface type (e.g. force `cylinder`). Records the override as a `reconstruct.*` attribute for the OCCTReconstruct engine to honour on its next pass; it does **not** re-fit here.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `sessionId` | string | yes | Reconstruction session id. |
| `node` | string | yes | Target node as `<kind>:<index>`. |
| `surfaceType` | string | yes | Forced surface type, e.g. `plane` / `cylinder` / `cone` / `sphere` / `torus`. |

**Returns** — Confirmation JSON with the node and the recorded `surfaceType` override, or an error if the session/node is not found.

**Example**

```json
// tool call arguments
{ "sessionId": "scan_part", "node": "face:5", "surfaceType": "cylinder" }
```
```json
// example result
{ "sessionId": "scan_part", "node": "face:5", "forcedSurfaceType": "cylinder" }
```

**Notes** — The override is stored as `reconstruct.forcedSurfaceType` on the node. The engine reads it on its next reconstruction pass; calling this tool alone does not change the geometry.

---

## `reconstruct_confirm_instances`

Confirm or reject a congruence cluster ("these N nodes are one part definition"). Tags every listed node with `clusterId` and the `confirmed` flag.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `sessionId` | string | yes | Reconstruction session id. |
| `clusterId` | string | yes | Identifier for the congruence cluster. |
| `nodes` | string[] | yes | Cluster member nodes as `<kind>:<index>`. |
| `confirmed` | boolean | no | Whether to confirm the cluster. Defaults to `true`. |

**Returns** — Confirmation JSON listing the cluster id, the nodes tagged, and the resulting `confirmed` state, or an error if the session is not found.

**Example**

```json
// tool call arguments — confirm a cluster of three faces as one part definition
{ "sessionId": "scan_part", "clusterId": "flange_boss", "nodes": ["face:2", "face:6", "face:9"], "confirmed": true }
```
```json
// example result
{ "sessionId": "scan_part", "clusterId": "flange_boss", "nodes": ["face:2", "face:6", "face:9"], "confirmed": true }
```

---

## `reconstruct_export_session`

Write the session's attributed graph snapshot to disk as byte-stable JSON. Defaults to `<output_dir>/reconstruct/<sessionId>.session.json`. Round-trips losslessly via `reconstruct_import_session`.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `sessionId` | string | yes | Reconstruction session id to export. |
| `path` | string | no | Optional output path. Overrides the default location. |

**Returns** — JSON with the path the snapshot was written to and the session id, or an error if the session is not found or the file cannot be written.

**Example**

```json
// tool call arguments
{ "sessionId": "scan_part" }
```
```json
// example result
{ "sessionId": "scan_part", "path": "/Users/you/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/reconstruct/scan_part.session.json" }
```

**Notes** — The output is byte-stable: the same session state always produces the same JSON bytes, making it safe to checksum or diff across saves.

---

## `reconstruct_import_session`

Reload a graph snapshot file into a session and return its current state. `sessionId` defaults to the file's stem (filename without extension).

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `path` | string | yes | Path to the `.session.json` snapshot file. |
| `sessionId` | string | no | Session id to assign. Defaults to the file stem. |

**Returns** — The reloaded session's graph state in the same shape as `reconstruct_get_graph`, or an error if the file cannot be read or parsed.

**Example**

```json
// tool call arguments
{ "path": "/Users/you/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/reconstruct/scan_part.session.json" }
```
```json
// example result
{
  "sessionId": "scan_part",
  "topologyCounts": { "face": 12, "edge": 30, "vertex": 20 },
  "annotatedNodes": [
    { "node": "face:3", "attributes": { "reconstruct.decidedBy": "human", "reconstruct.accepted": true, "reconstruct.forcedSurfaceType": "cylinder" } }
  ],
  "instanceClusters": [
    { "clusterId": "flange_boss", "nodes": ["face:2", "face:6", "face:9"], "confirmed": true }
  ]
}
```

**Notes** — Use `reconstruct_export_session` / `reconstruct_import_session` to persist a session across server restarts or share it between runs.
