---
title: Reconstruction graph
parent: Cookbook
nav_order: 12
---

# Reconstruction graph

**Swift only** — the `reconstruct_*` tools require the Swift `occtmcp-server`.
{: .note }

This recipe walks the annotate-and-persist layer over an **attributed reconstruction graph**. OCCTMCP exposes topology as nodes addressed `<kind>:<index>` (e.g. `face:3`) and lets an LLM write per-node `reconstruct.*` attributes: decisions, fit overrides, and instance membership. The fitting **engine** lives in OCCTReconstruct; [`reconstruct_force_fit`](../../reference/reconstruction.md#reconstruct_force_fit) records an override attribute — it does **not** re-fit.

See the [Reconstruction graph reference](../../reference/reconstruction.md) for full parameter tables.

---

## 1. Start a session

Call [`reconstruct_get_graph`](../../reference/reconstruction.md#reconstruct_get_graph) with a `bodyId` to open a session. The returned `sessionId` is the handle for every subsequent call.

```json
{ "bodyId": "scan_part" }
```

```json
{
  "sessionId": "scan_part",
  "topologyCounts": { "face": 12, "edge": 30, "vertex": 20 },
  "annotatedNodes": [],
  "instanceClusters": []
}
```

The graph has 12 faces, 30 edges, and 20 vertices — all unannotated so far. Resume an existing session by passing `sessionId` instead of `bodyId`.

---

## 2. Annotate a node's decision

Use [`reconstruct_set_decision`](../../reference/reconstruction.md#reconstruct_set_decision) to record who made a fit decision and whether it is accepted. Supply at least one of `decidedBy` or `accepted`.

```json
{
  "sessionId": "scan_part",
  "node": "face:3",
  "decidedBy": "human",
  "accepted": true
}
```

```json
{
  "sessionId": "scan_part",
  "node": "face:3",
  "updated": {
    "reconstruct.decidedBy": "human",
    "reconstruct.accepted": true
  }
}
```

Repeat for each node you want to annotate. A subsequent `reconstruct_get_graph` call (with `sessionId`) will list all annotated nodes.

---

## 3. Override a surface type

If a face was fitted as `plane` but you know it should be `cylinder`, record the override with [`reconstruct_force_fit`](../../reference/reconstruction.md#reconstruct_force_fit). This writes `reconstruct.forcedSurfaceType` onto the node; the OCCTReconstruct engine honours it on its next pass.

```json
{
  "sessionId": "scan_part",
  "node": "face:5",
  "surfaceType": "cylinder"
}
```

```json
{
  "sessionId": "scan_part",
  "node": "face:5",
  "forcedSurfaceType": "cylinder"
}
```

Valid values for `surfaceType`: `plane`, `cylinder`, `cone`, `sphere`, `torus`.

---

## 4. Confirm a congruence cluster

When you identify a set of nodes that form one part definition (congruent instances), call [`reconstruct_confirm_instances`](../../reference/reconstruction.md#reconstruct_confirm_instances). Every listed node is tagged with the `clusterId` and the `confirmed` flag.

```json
{
  "sessionId": "scan_part",
  "clusterId": "flange_boss",
  "nodes": ["face:2", "face:6", "face:9"],
  "confirmed": true
}
```

```json
{
  "sessionId": "scan_part",
  "clusterId": "flange_boss",
  "nodes": ["face:2", "face:6", "face:9"],
  "confirmed": true
}
```

Pass `"confirmed": false` to reject a cluster the engine proposed.

---

## 5. Persist the session

[`reconstruct_export_session`](../../reference/reconstruction.md#reconstruct_export_session) writes a byte-stable JSON snapshot. The default path is `<output_dir>/reconstruct/<sessionId>.session.json`.

```json
{ "sessionId": "scan_part" }
```

```json
{
  "sessionId": "scan_part",
  "path": "/Users/you/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/reconstruct/scan_part.session.json"
}
```

The snapshot is byte-stable: the same session state always produces identical bytes, so it is safe to checksum or diff across saves. Pass an optional `path` to write elsewhere.

---

## 6. Reload a session

[`reconstruct_import_session`](../../reference/reconstruction.md#reconstruct_import_session) reads a snapshot file back into memory and returns the full graph state. Use this after a server restart or to hand off a session between runs.

```json
{
  "path": "/Users/you/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/reconstruct/scan_part.session.json"
}
```

```json
{
  "sessionId": "scan_part",
  "topologyCounts": { "face": 12, "edge": 30, "vertex": 20 },
  "annotatedNodes": [
    {
      "node": "face:3",
      "attributes": {
        "reconstruct.decidedBy": "human",
        "reconstruct.accepted": true
      }
    },
    {
      "node": "face:5",
      "attributes": {
        "reconstruct.forcedSurfaceType": "cylinder"
      }
    }
  ],
  "instanceClusters": [
    { "clusterId": "flange_boss", "nodes": ["face:2", "face:6", "face:9"], "confirmed": true }
  ]
}
```

`sessionId` defaults to the file stem (`scan_part` here); pass an explicit `sessionId` to assign a different handle.
