---
type: component
title: execute_script
resource: https://github.com/SecondMouseAU/OCCTMCP/blob/main/Sources/OCCTMCPCore/Tools/ExecuteScriptTool.swift
tags: [component, execute-script, occtkit, manifest, viewport]
description: The data flow behind execute_script, and why writing manifest.json is the side effect that matters.
generated: { by: human:gsdali, at: 2026-09-06 }
---

# execute_script

1. Writes the LLM's Swift code to a per-call tempfile under `os.tmpdir()` and stashes the source for `get_script`.
2. Calls `occtkit run <tempfile>` via the resolved binary (PATH > sibling-repo `swift run -c release occtkit`). Cold start of the underlying SwiftPM workspace is 60+s on first call; subsequent calls amortise via OCCTSwiftScripts' serve mode where available.
3. Filters noisy OCCT bridge nullability warnings from build output; compiler diagnostics still reach the LLM under the `Script failed.` prefix.
4. Reads `manifest.json` from the output directory and returns it with build output. `executeScript` calls `snapshotScene()` before running so `compare_versions` has history.
5. Removes the tempfile in a `finally` block.

Writing `manifest.json` is the side effect that matters: `OCCTSwiftViewport`'s `ScriptWatcher` watches that file, so emitting it triggers the live 3D reload.

The 2 min timeout is per-request.
