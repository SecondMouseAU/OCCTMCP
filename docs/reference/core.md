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

Compile and run an arbitrary Swift CAD script via a cached SPM workspace. The script writes into a
private stage directory, never the scene; when it succeeds, its manifest and BREP files replace the
scene.

**Server:** Swift + Node. The stage directory, the failure checks and the promotion described here
are the Swift server's; the Node server runs `occtkit` against the scene directory as before.

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `code` | string | yes | Complete Swift source for main.swift. |
| `description` | string | no | Short description of what this script creates. |

**Returns**: The updated scene manifest (body list, colors, materials) plus any build/compiler
output. On compilation failure, returns the compiler diagnostics under a `Script failed.` prefix.
A script that exits non-zero, calls `ctx.fail(_:)` (its message follows `Reason:`), writes a manifest
that cannot be read, or lists a file it did not write, fails the call and leaves the scene as it was.
A script that never calls `ctx.emit()` succeeds, says it wrote no manifest and changes nothing.

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

**Notes**: The script's `ScriptContext` writes to the directory named by `OCCTSWIFT_OUTPUT_DIR`,
which OCCTMCP sets to a new directory under the system temp directory, outside the scene. A clean
run is promoted by replacing the scene with what the script emitted (a script's manifest has always
meant "the scene as this script built it"): the new bodies' files are copied in under names that no
earlier file has, `manifest.json` is swapped under the manifest lock, and the files the previous
manifest listed are then removed, so a failure before the swap leaves the old scene whole. Other
files in the scene directory, `annotations.json` among them, are not touched; `provenance.json` is
cleared, as `clear_scene` clears it. The stage is removed afterwards. The SPM workspace is
`~/.occtmcp-cache/workspace`, or the directory in `OCCTMCP_SCRIPT_WORKSPACE` when that is set. Cold
start is ~60 s on the first call (full SPM build of OCCTSwift); subsequent calls
are ~1–2 s incremental. Fallible OCCTSwift factories return optionals: unwrap with `guard let`,
never force-unwrap. Boolean operators on `Shape`: `a - b` subtract, `a + b` union, `a & b`
intersect. The manifest write triggers the OCCTSwiftViewport live 3D reload.

**Drives**: `occtkit run <tempfile>` (Node); the cached SPM workspace and `ScriptHarness` (Swift).

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

### What an extra tool can hold, add and report

A handler is a closure, so it can carry whatever the tool needs between calls. A pair of tools
that share a ledger, a solve or a recipe the human is editing hold it the same way:

```swift
actor Ledger {
    private var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
    var all: [String] { entries }
}

let ledger = Ledger()
let extras = [
    ExtraTool(tool: ledgerAddTool, handler: { args in
        await ledger.append(args["entry"]?.stringValue ?? "")
        return .init(content: [.text(text: "recorded", annotations: nil, _meta: nil)])
    }),
    ExtraTool(tool: ledgerListTool, handler: { _ in
        .init(content: [.text(text: await ledger.all.joined(separator: ","), annotations: nil, _meta: nil)])
    }),
]
```

- The state lives as long as the closure that holds it, so one `Ledger` per server is one session.
  Handlers run concurrently (the SDK handles each request on its own task), so guard shared
  state with an actor or a lock, as above.
- A tool call is not retried and has no identity beyond its arguments: a handler that needs to
  tie one call to another does it through its own state or through the scene.

**Adding a body to the scene.** `SceneBodies.add(shape:)` writes a BREP body into the scene and
returns the id it was given. It is the code `read_brep` and `import_file` use, so a body a handler
adds is staged beside the manifest, moved into place under the manifest lock, pushed onto
`SceneHistory` (so `compare_versions` can diff against it), and reported to the host's
`manifestWriteObserver` under the handler's own tool name.

```swift
let id = try await SceneBodies.add(shape: solid, idPrefix: "profile", color: [0.8, 0.2, 0.2, 1])
// "profile", or "profile_1" if that id was taken. Built-in tools take it as `bodyId`.
```

- Pass `bodyId` to choose the id. A taken id throws `ManifestError.bodyIdTaken` and leaves the
  existing body alone. Without it the first free `idPrefix`, `idPrefix_1`, `idPrefix_2` is used,
  chosen under the manifest lock, so concurrent adds with one prefix each get their own id.
- A body's file is `<id>.brep`. An add whose file name another body already has, compared without
  regard to case because the scene may sit on a case-insensitive volume, throws
  `SceneBodiesError.fileInUse` and overwrites nothing; a generated id skips such names. `read_brep`
  and `import_file` apply the same rule.
- An id names the body's file, so it must not be empty, start with a dot or contain `/`; anything
  else throws `SceneBodiesError.invalidBodyId` before anything is written. `read_brep` and
  `import_file` now apply the same rule.
- `allowInvalid: true` writes a shape that fails validation, as `import_file` does for a mesh shell.
- It does not check that the shape has an extent. `read_brep` does, and a handler that reports a
  bounding box should check `shape.bounds` first.
- The body is always written as BREP. A handler that wants a `step` body writes the file and the
  manifest entry itself, through `ManifestStore.update`.

**Finding a body again.** `SceneBodies.body(withId:)` returns the manifest entry and
`SceneBodies.shape(ofBody:)` returns its shape, read the way a built-in reading tool reads it: the
host's own shape from `bodyShapeProvider` when it supplies one, else the body's file read by its
`format`, parsed afresh on each call. That is right for geometry: measure it, take a volume, tessellate
it. It is not a way to resolve a `selectionId` or a `GraphUID`. Those resolve through the body's
retained lineage graph, a node index there is not a position in `Shape.faces()`, and a freshly parsed
shape is not a node of that graph. A host that holds the shape its picks index into returns it from
`bodyShapeProvider`, and the shape a handler reads here is then that same one. Errors are
`IntrospectionTools.ToolError` (no scene, no such body, file missing) or `BodyLoadError` (unreadable
file); a handler that lets one escape produces an `isError` result that names it.

Both resolve the scene directory from the calling task, so they must run on the tool call's own
task or a child of it. `Task.detached` drops the directory passed to `outputDirectory:` and falls
back to the process default.

**Progress.** `OCCTMCPContext.reportProgress(_:total:message:)` sends `notifications/progress`
for the running call when the client put a `progressToken` in the request's `_meta`, and does
nothing otherwise, so a handler calls it unconditionally:

```swift
for (i, step) in steps.enumerated() {
    try Task.checkCancellation()
    try await step.run()
    await OCCTMCPContext.reportProgress(Double(i + 1), total: Double(steps.count), message: step.name)
}
```

Send values that rise with each call, and only while the handler is running: the spec ends a
request's progress when it completes. A notification that cannot be sent is dropped and never fails
the call. The built-in tools do not report progress today; this is for handlers that run for
seconds, such as a constraint solve.

**Cancellation.** When a client sends `notifications/cancelled`, the SDK cancels the Swift task
running the handler. A handler awaiting a cancellable call (`Task.sleep`, a `URLSession` request) is
interrupted at that await. Awaiting an actor's method is not a cancellation point, and neither is a
synchronous loop: check `try Task.checkCancellation()` between steps. Rethrow `CancellationError`
rather than turning it into a result. A handler that ignores the cancellation runs to its end,
because the server waits for it, but the server then sends no response for a request that was
cancelled, as the MCP spec asks, whatever the handler returned. The host's `toolCallObserver` still
sees the call finish.

## Embedding: promoting a script's output

`execute_script` runs the script against a stage directory (see above) and promotes a clean run
itself, by replacing the scene. A host that owns its scene store takes the last step instead:

```swift
let server = await makeOCCTMCPServer(
    outputDirectory: sceneDirectory,
    scriptStagePromoter: { stage, sceneDirectory in
        // `stage` holds what the script wrote: manifest.json, the body files it lists, and any
        // artefacts such as output.step. Put it into the scene the way the host does.
        try await sceneStore.promote(stage: stage, into: sceneDirectory)
    })
```

- The promoter is called only for a run that exited zero, left no `run-failed.json` and wrote a
  manifest that parses and lists only plain file names the stage holds. A failed run, a run that
  wrote no manifest, and a bad manifest are reported to the agent without calling it, and the
  scene is left as it was.
- With a promoter nothing is copied into the scene for it: the scene is the host's to change. The
  prior scene is still pushed onto `SceneHistory`, once the promoter has returned without throwing.
- The stage is outside the scene directory by construction, so a host can refuse a stage inside its
  own scene. OCCTMCP removes the stage when the promoter returns, whether it returned or threw; a
  host that wants to keep any of it (a quarantined stage to retry, say) moves it first.
- A promoter that throws fails the call: `Script ran, but promoting its output into the scene
  failed: <reason>`. What state it left the scene in is the host's to know.
- `ExecuteScriptTool.execute(code:...promoter:)` takes the same closure for a host that wraps the
  tool; it defaults to the one given to `makeOCCTMCPServer`, scoped to the tool call like the
  observers above.
- The child is told `OCCTSWIFT_OUTPUT_DIR`. OCCTMCP never exports `OCCTMCP_OUTPUT_DIR`, which names
  the scene and which the harness does not read.

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
