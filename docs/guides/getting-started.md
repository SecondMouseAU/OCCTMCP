---
title: Getting started
nav_order: 4
---

# Getting started

This page covers installing OCCTMCP, wiring it into an MCP client, and making your first tool calls.

## Prerequisites

### Swift server (recommended)

- macOS 15+
- Swift 6.1+ / Xcode 16+

### Node server

- Node.js 18+
- The `occtkit` CLI on `$PATH` — install it by running `make install` inside a clone of
  [OCCTSwiftScripts](https://github.com/SecondMouseAU/OCCTSwiftScripts), or keep a sibling clone at
  `~/Projects/OCCTSwiftScripts` so OCCTMCP can fall back to `swift run -c release occtkit` automatically

The Node server exposes a 37-tool subset; the Swift server exposes all 74 tools (selection, remap,
annotations, reconstruction, mesh-zone analysis, mesh inspection, alignment, and more are
Swift-only). See the [Tool Reference](../reference/) for per-tool server availability.

---

## Build

### Swift

```bash
git clone https://github.com/SecondMouseAU/OCCTMCP.git
cd OCCTMCP
swift build -c release
# binary at: .build/release/occtmcp-server
```

### Node

```bash
git clone https://github.com/SecondMouseAU/OCCTMCP.git
cd OCCTMCP
npm install
npm run build
# entry point at: dist/index.js
```

---

## Wire into an MCP client

Both blocks assume you cloned to `/path/to/OCCTMCP`. Replace that with the absolute path on your
machine.

### Swift server

```json
{
  "mcpServers": {
    "occtmcp": {
      "command": "/path/to/OCCTMCP/.build/release/occtmcp-server"
    }
  }
}
```

### Node server

```json
{
  "mcpServers": {
    "occtmcp": {
      "command": "node",
      "args": ["/path/to/OCCTMCP/dist/index.js"]
    }
  }
}
```

Both servers speak stdio MCP and read/write the same scene files, so you can swap them without
changing any other tooling.

---

## Output directory

Every tool resolves the output directory in this order:

1. `OCCTMCP_OUTPUT_DIR` environment variable (set this to redirect to a temp dir or a project folder)
2. iCloud Drive: `~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/`
3. Local fallback: `~/.occtswift-scripts/output/`

The scene files written there are:

- `manifest.json` — the current scene (body IDs, colors, file paths)
- `annotations.json` — dimensions and scene primitives
- One `.brep` file per body

To set a custom output dir in your MCP client config, add an `env` key:

```json
{
  "mcpServers": {
    "occtmcp": {
      "command": "/path/to/OCCTMCP/.build/release/occtmcp-server",
      "env": {
        "OCCTMCP_OUTPUT_DIR": "/tmp/occt-session"
      }
    }
  }
}
```

---

## First call walkthrough

### 1. Build a box with `execute_script`

For geometry the typed tools don't cover, the LLM authors a short Swift script. Here is the minimal
template — the only correct shape:

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

let box = Shape.box(width: 60, height: 40, depth: 20)!

try ctx.add(box, id: "box", color: C.steel, name: "Box")
try ctx.emit(description: "Simple box 60×40×20 mm")
```

Pass that as the `script` argument to `execute_script`:

```json
{
  "tool": "execute_script",
  "arguments": {
    "script": "import OCCTSwift\nimport ScriptHarness\n\nlet ctx = ScriptContext()\nlet C = ScriptContext.Colors.self\n\nlet box = Shape.box(width: 60, height: 40, depth: 20)!\n\ntry ctx.add(box, id: \"box\", color: C.steel, name: \"Box\")\ntry ctx.emit(description: \"Simple box 60×40×20 mm\")"
  }
}
```

The tool compiles and runs the script, writes `box.brep` and `manifest.json` to the output
directory, and returns the updated manifest.

### 2. Read the scene with `get_scene`

```json
{
  "tool": "get_scene",
  "arguments": {}
}
```

Returns the manifest — body IDs, display names, colors, and output-file paths. Use the `bodyId`
values (`"box"` here) to target subsequent tools.

### 3. Render a preview with `render_preview`

```json
{
  "tool": "render_preview",
  "arguments": {
    "bodyIds": ["box"],
    "camera": "iso"
  }
}
```

Returns the path to a PNG file rendered from the `iso` camera preset. Measurement labels and
primitive overlays are composited automatically if you have added any via `add_dimension` or
`add_scene_primitive`.

---

## Next steps

- **[Cookbook](../guides/cookbook/)** — task-oriented recipes for construction, analysis, selection,
  annotations, import/export, and more
- **[Tool Reference](../reference/)** — every tool's parameters, return shape, and an example call
