---
title: Scene mutation
parent: Tool Reference
nav_order: 2
---

# Scene mutation

These tools reshape the live scene manifest — adding, removing, renaming, recolouring, and comparing
bodies — without re-running a script. Every write triggers an automatic viewport reload via
`ScriptWatcher`.

## Tools

- [`remove_body`](#remove_body) · [`clear_scene`](#clear_scene) · [`rename_body`](#rename_body) · [`set_appearance`](#set_appearance) · [`compare_versions`](#compare_versions)

---

## `remove_body`

Delete a single body from the scene by id. Removes the body's BREP file from the output directory
and re-emits the manifest.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | The id of the body to remove. |

**Returns** — Confirmation text, or an error if the body id is not found in the manifest.

**Example**

```json
// tool call arguments
{ "bodyId": "bracket" }
```
```json
// example result
{ "removed": "bracket" }
```

---

## `clear_scene`

Remove every body from the current scene. Optionally preserves the `compare_versions` history ring
buffer so diffs against earlier states remain available after the reset.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `keepHistory` | boolean | no | If true, keep the compare_versions history ring. Default false. |

**Returns** — Confirmation text listing how many bodies were removed.

**Example**

```json
// tool call arguments
{ "keepHistory": true }
```
```json
// example result
{ "cleared": 3 }
```

---

## `rename_body`

Change a body's id in the scene manifest. Fails if the new id is already in use.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Current id of the body to rename. |
| `newBodyId` | string | yes | The replacement id. Must not already exist in the scene. |

**Returns** — Confirmation text, or an error if `bodyId` is not found or `newBodyId` is taken.

**Example**

```json
// tool call arguments
{ "bodyId": "part", "newBodyId": "housing" }
```
```json
// example result
{ "renamed": { "from": "part", "to": "housing" } }
```

---

## `set_appearance`

Update colour, opacity, roughness, metallic, or display name for a scene body without re-running a
script. The viewport reloads automatically.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Id of the body whose appearance to update. |
| `color` | number[] | no | RGBA or RGB array (0–1 per channel). |
| `opacity` | number | no | Sets colour alpha (0–1). Leaves RGB unchanged. |
| `roughness` | number | no | PBR roughness (0–1). |
| `metallic` | number | no | PBR metallic factor (0–1). |
| `name` | string | no | Display name shown in the viewport body list. |

**Returns** — Confirmation text with the updated appearance values, or an error if the body is not
found.

**Example**

```json
// tool call arguments
{ "bodyId": "housing", "color": [0.8, 0.2, 0.1], "opacity": 0.7, "name": "Housing (translucent)" }
```
```json
// example result
{ "updated": "housing", "color": [0.8, 0.2, 0.1, 0.7], "name": "Housing (translucent)" }
```

---

## `compare_versions`

Diff the current scene against a snapshot from N `execute_script` runs ago. Detects added, removed,
appearance-changed, and BREP-file-changed bodies. Snapshots are held in an in-memory ring buffer of
the last 10 runs; requesting `since` beyond the available depth returns an error.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `since` | integer ≥ 1 | no | How many runs back to compare against. Default 1. |

**Returns** — A diff object with `added`, `removed`, `appearanceChanged`, and `fileChanged` arrays
of body ids, plus the snapshot age. Returns an error if fewer than `since` snapshots exist.

**Example**

```json
// tool call arguments
{ "since": 2 }
```
```json
// example result
{
  "since": 2,
  "added": ["rib"],
  "removed": [],
  "appearanceChanged": ["housing"],
  "fileChanged": ["housing"]
}
```

**Notes** — The ring buffer is in-memory: it resets when the server restarts. Use `keepHistory: true`
on `clear_scene` to retain snapshots across a scene reset. Snapshots are taken by `execute_script`
before each run, so pure manifest mutations (rename, set_appearance, etc.) do not advance the counter.
