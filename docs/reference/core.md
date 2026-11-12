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

**Returns**: The updated scene manifest (body list, colors, materials) plus any build/compiler
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

**Notes**: Cold start is ~60 s on the first call (full SPM build of OCCTSwift); subsequent calls
are ~1–2 s incremental. Fallible OCCTSwift factories return optionals: unwrap with `guard let`,
never force-unwrap. Boolean operators on `Shape`: `a - b` subtract, `a + b` union, `a & b`
intersect. The manifest write triggers the OCCTSwiftViewport live 3D reload.

**Drives**: `occtkit run <tempfile>` (Node); in-process `ScriptHarness` evaluation (Swift).

---

## `get_script`

Return the source of the most recent Swift CAD script executed in this session.

**Server:** Swift + Node

No parameters.

**Returns**: The Swift source string of the last `execute_script` call in this session, or an
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

**Returns**: The contents of `manifest.json`: the list of bodies currently in the scene, each
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

**Returns**: A list of file paths for every recognised CAD export format found in the output
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

**Returns**: When `category` is `"mcp_tools"`: the full JSON Schema of every registered tool,
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

**Notes**: Call this at session start with `category: "mcp_tools"` to let the LLM discover the
full tool surface without relying on static documentation.

---

## `ping`

Sanity-check tool: returns `"pong"` so callers can verify the OCCTMCP Swift server is alive.

**Server:** Swift only

No parameters.

**Returns**: The string `"pong"`.

**Example**

```json
// tool call arguments
{}
```

```json
// example result
"pong"
```

## Embedding: extra tools

A Swift host that links `OCCTMCPCore` can serve tools of its own beside OCCTMCP's. Registering a
handler on the returned `Server` replaces OCCTMCP's `ListTools` and `CallTool` handlers, so pass the
extra tools to the factory instead:

```swift
let server = await makeOCCTMCPServer(extraTools: [
    ExtraTool(
        tool: Tool(name: "get_scene_hierarchy", description: "...", inputSchema: .object([:])),
        handler: { arguments in
            .init(content: [.text(text: "...", annotations: nil, _meta: nil)], isError: false)
        })
])
```

- Extra tools are listed after the built-ins and are dispatched before them.
- A name that matches a built-in replaces it: the built-in is dropped from `ListTools` and is never
  called, so the name appears exactly once.
- If several extras share a name, the last one in the array wins.
- A handler that throws produces an error result (`isError: true`); the server keeps running.
- `get_api_reference` with `category: "mcp_tools"` lists the live catalog, so it includes the extra
  tools and omits any built-in they replaced.
- With no extras (the default) the catalog and behaviour are unchanged.

## Embedding: observing tool calls and manifest writes

Two optional arguments to `makeOCCTMCPServer` let a host see what the built-in tools do:

```swift
let server = await makeOCCTMCPServer(
    outputDirectory: sceneDirectory,
    manifestWriteObserver: { bytes, tool in
        // Under the manifest lock, before the atomic rename. `tool` is the running tool's name.
        record(bytes, attributedTo: tool)
    },
    toolCallObserver: { event in
        // `.started`, then `.finished(isError:)`, for each `tools/call`.
        show(event.name, event.arguments, event.phase)
    })
```

- `manifestWriteObserver` runs inside `ManifestStore` for every write a tool makes, so a new
  mutating tool is covered without changes. Throwing aborts the write. `OCCTMCPContext.currentTool`
  holds the name; it is nil for a write made outside a tool call.
- `toolCallObserver` receives events one at a time, in order, on its own task: a slow observer never
  delays a tool result. Events carry a `callID` that ties a start to its finish.
- With neither set (the default) behaviour is unchanged.

## Body formats, and supplying a body's shape

A manifest body carries a `format`, and every tool that reads a body's shape reads its file by
that format: `brep` through `Shape.loadBREP`, `step` through the STEP reader, and `iges`, `stl`
and `obj` as `import_file` does (one shared reader, so a body and an import of the same file
agree). The value is matched case-insensitively and `stp`, `igs` and `brp` are accepted. STEP is
read with a 1 mm target unit, as `import_file` reads it. A format outside that list is an error
that names it, as is a file that does not parse:

```text
Failed to read step body "valve" from /scene/valve.step: Failed to read /scene/valve.step: <status>
Body "valve" has format "glb", which this server cannot read. Supported formats: step, iges, obj, brep, stl.
```

Tools that write a body back write BREP and copy the input body's `format` onto the result:
`transform_body`, `apply_feature`, `heal_shape` and `align_bodies` overwrite the body's own file,
and `boolean_op` and `mirror_or_pattern` write a new file. A `step` body would be overwritten
with BREP bytes or a BREP file would be labelled `step`, so these accept `brep` bodies only and
refuse any other with `This tool edits brep bodies only`, leaving the file and the manifest as
they were. The raw-path tools (`graph_validate`, `graph_compact` and the other `brep_path`
tools) read BREP by construction.

A host that already holds a body's shape can hand it to the tools, so a pick the host made and
the entity a tool reads are the same one. A STEP assembly read twice can come back with a
different face order or different `GraphUID`s, and the host's own copy is the one its picks index
into:

```swift
let server = await makeOCCTMCPServer(
    outputDirectory: sceneDirectory,
    bodyShapeProvider: { body, outputDir in
        // The shape the host loaded for this body, or nil to let the tool read the file.
        hostScene.shape(forBodyId: body.id)
    })
```

- The provider is consulted first, by every read of a body's shape, including the history-aware
  reads behind `select_topology`, `get_selection`, `auto_dimension`, `select_by_feature` and
  `measure_distance`. Returning nil falls through to the format dispatch above. Throwing fails
  the tool call, except in the few lookups that already treat an unreadable body as absent
  (`remap_selection`, the `diff_overlay` markers and the source side of `find_correspondences`),
  where it counts as unreadable.
- The body's file stays the manifest's record of it, and most tools check it exists before asking
  the provider, so a host should still write the file. The provider replaces reading it.
- The retained lineage graph for a body is built from the provided shape and cached by that
  shape's identity as well as by the body file's fingerprint. A host that swaps the shape it holds
  without touching the file gets a rebuilt lineage, so a `selectionId`'s index and uid stay those
  of the shape the host holds. A lookup the host declines reads the file, never the host's old
  shape.
- Editing tools never ask the provider: they start from the body's file, and `align_bodies` with
  `apply: true` reads the file it is about to overwrite (a dry run reads like any other tool). A
  lineage built from the host's shape is not continued into an edit, so an edit runs on the same
  input whichever tool ran before it, and a `GraphUID` minted from a host pick does not survive
  the edit; `remap_selection` then resolves it by a lower rung. For the same reason a host-backed
  read of a body after an edit rebuilds its lineage from the host's shape (a refreshed copy is a
  different shape from the edit's output), which drops the history the edit recorded, so call
  `remap_selection` before reading the body again. A host that supplies shapes for bodies those
  tools edit should refresh its copy when the manifest changes, as it would for any edit.
- The registry keeps the host's shape alive in the body's lineage entry until that body is looked
  up again, renamed or cleared, so a host that drops a large body can find it retained.
- The provider is called synchronously, on whichever executor the tool is already running on:
  the main actor for `render_preview`, `pick_surface_point`, `align_bodies` and the mesh, heatmap,
  zone, fit and symmetry tools, and inside the history registry's actor for the lineage reads
  (`select_topology`, `get_selection`, `auto_dimension`, `select_by_feature`, `measure_distance`).
  It must return without waiting on either: a hop to the main actor with `DispatchQueue.main.sync`
  deadlocks in the main-actor tools, and `MainActor.assumeIsolated` traps in the rest. Keep the
  shapes in a lock-protected map and read that. The tool is handed the shape itself, uncopied, so
  the host also owns synchronisation of anything else that reads it while a tool runs.
- A tool that tessellates a body (`generate_mesh`, `render_preview`, `pick_surface_point` and the
  mesh and deviation tools) meshes the provided shape itself, and OCCT keeps a triangulation on
  the shape it meshes. A host that keeps its own display triangulation on that shape can return a
  copy for those tools, at the cost of the shared identity above, or accept that they share it.
- The provider is a task-local scoped to each tool call, like the observers above, so two servers
  in one process never see each other's. It is not seen from a `Task.detached`.
- With no provider (the default) behaviour is unchanged for `brep` bodies.

## Embedding: committing the manifest

Every built-in tool that changes the scene commits `manifest.json` through
`ManifestStore.update`, so a host that writes the manifest itself can take part in the same lock:

```swift
let store = ManifestStore(path: "\(sceneDirectory)/manifest.json")
let written = try store.update(willWrite: { bytes in
    // The exact bytes about to land, under the lock, before the atomic rename.
    digestOfOwnWrite = sha256(bytes)
}) { current in
    // `current` is nil when the file is absent.
    let current = try current.requiringScene()
    return current.replacing(bodies: current.bodies.filter { $0.id != "old" })
}
```

- `update` takes an advisory `flock` on `manifest.lock` in the scene directory (a separate file,
  because the atomic write replaces the manifest's inode), reads, runs the transform, calls
  `willWrite`, writes atomically, and releases. `ManifestStore.write` takes the same lock.
- Throwing from the transform or from `willWrite` aborts the write and leaves the file untouched.
- A malformed `manifest.json` throws `ManifestError.malformed`, from `update` and from every
  built-in tool, and is never overwritten. Tools no longer report it as "No scene loaded".
- The lock is not re-entrant: calling `update` or `write` on the same path from inside a closure
  waits `lockTimeout` (30 s by default) and throws `ManifestError.lockTimeout`.
- The guarantee holds between processes that know the lock. An OCCTMCP or `occtkit` that does not
  can still lose updates.
