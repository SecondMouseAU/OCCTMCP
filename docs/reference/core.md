---
title: Core & scripting
parent: Tool Reference
nav_order: 1
---

# Core & scripting

The core family is the entry point for every OCCTMCP session: `execute_script` builds or rebuilds
the 3D scene by running Swift CAD code; the remaining tools read state back out (scene manifest,
last script, exported files, server liveness) or surface the live tool catalog for LLM
auto-discovery.

## Tools

[`execute_script`](#execute_script) · [`get_script`](#get_script) · [`get_scene`](#get_scene) · [`export_model`](#export_model) · [`get_api_reference`](#get_api_reference) · [`ping`](#ping)

---

## `execute_script`

Compile and run an arbitrary Swift CAD script via a cached SPM workspace, writing `manifest.json`
and BREP files to the output directory.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `code` | string | yes | Complete Swift source for main.swift. |
| `description` | string | no | Short description of what this script creates. |

**Returns** — The updated scene manifest (body list, colors, materials) plus any build/compiler
output. On compilation failure, returns the compiler diagnostics under a `Script failed.` prefix.

**Example**

```json
// tool call arguments
{
  "description": "10 mm steel cube",
  "code": "import OCCTSwift\nimport ScriptHarness\n\nlet ctx = ScriptContext()\nlet C = ScriptContext.Colors.self\n\nguard let box = Shape.box(width: 10, height: 10, depth: 10) else {\n    throw ScriptError.message(\"box failed\")\n}\n\ntry ctx.add(box, id: \"cube\", color: C.steel, name: \"Cube\")\ntry ctx.emit(description: \"10 mm steel cube\")\n"
}
```

```swift
// canonical script template
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

// ... build geometry with the OCCTSwift API (Shape.box, .cylinder, booleans, etc.) ...

try ctx.add(shape, id: "part", color: C.steel, name: "My Part")
try ctx.emit(description: "what this model is")
```

```json
// example result
{
  "bodies": [
    { "id": "cube", "name": "Cube", "color": "steel", "brepFile": "cube.brep" }
  ],
  "description": "10 mm steel cube"
}
```

**Notes** — Cold start is ~60 s on the first call (full SPM build of OCCTSwift); subsequent calls
are ~1–2 s incremental. Fallible OCCTSwift factories return optionals — unwrap with `guard let`,
never force-unwrap. Boolean operators on `Shape`: `a - b` subtract, `a + b` union, `a & b`
intersect. The manifest write triggers the OCCTSwiftViewport live 3D reload.

**Drives** — `occtkit run <tempfile>` (Node); in-process `ScriptHarness` evaluation (Swift).

---

## `get_script`

Return the source of the most recent Swift CAD script executed in this session.

**Server:** Swift + Node

No parameters.

**Returns** — The Swift source string of the last `execute_script` call in this session, or an
error if no script has been run yet.

**Example**

```json
// tool call arguments
{}
```

```json
// example result
{
  "source": "import OCCTSwift\nimport ScriptHarness\n\nlet ctx = ScriptContext()\n..."
}
```

---

## `get_scene`

Read the current scene manifest (bodies, colors, materials).

**Server:** Swift + Node

No parameters.

**Returns** — The contents of `manifest.json`: the list of bodies currently in the scene, each
with its `id`, `name`, `color`, material, and BREP file reference.

**Example**

```json
// tool call arguments
{}
```

```json
// example result
{
  "bodies": [
    { "id": "part", "name": "My Part", "color": "steel", "brepFile": "part.brep" }
  ],
  "description": "A simple test part"
}
```

---

## `export_model`

List exported model files (BREP, STEP, STL, OBJ, IGES, glTF, JSON) from the current output
directory.

**Server:** Swift + Node

No parameters.

**Returns** — A list of file paths for every recognised CAD export format found in the output
directory. Does not trigger an export; use `export_scene` (scene-mutation family) to write new
files.

**Example**

```json
// tool call arguments
{}
```

```json
// example result
{
  "files": [
    "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/part.brep",
    "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/part.step"
  ]
}
```

---

## `get_api_reference`

Returns a catalog of every MCP tool this server exposes (`category=mcp_tools`), or a pointer to
OCCTSwift docs for the OCCT API categories.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `category` | string | no | `'mcp_tools'` for the live tool catalog; any other value returns a pointer to the OCCTSwift sources / docs. |

**Returns** — When `category` is `"mcp_tools"`: the full JSON Schema of every registered tool,
suitable for LLM auto-discovery. Otherwise: a pointer to OCCTSwift source documentation.

**Example**

```json
// tool call arguments (request the live tool catalog)
{ "category": "mcp_tools" }
```

```json
// example result (truncated)
{
  "tools": [
    {
      "name": "execute_script",
      "description": "Compile and run an arbitrary Swift CAD script …",
      "inputSchema": { "type": "object", "properties": { "code": { "type": "string" } } }
    }
  ]
}
```

**Notes** — Call this at session start with `category: "mcp_tools"` to let the LLM discover the
full tool surface without relying on static documentation.

---

## `ping`

Sanity-check tool — returns `"pong"` so callers can verify the OCCTMCP Swift server is alive.

**Server:** Swift only

No parameters.

**Returns** — The string `"pong"`.

**Example**

```json
// tool call arguments
{}
```

```json
// example result
"pong"
```
