---
type: component
title: execute_script
resource: https://github.com/SecondMouseAU/OCCTMCP/blob/main/Sources/OCCTMCPCore/Tools/ExecuteScriptTool.swift
tags: [component, execute-script, occtkit, manifest, viewport]
description: The data flow behind execute_script, and why writing manifest.json is the side effect that matters.
generated: { by: human:gsdali, at: 2026-09-06 }
---

# execute_script

1. Writes the LLM's Swift code into the cached SwiftPM workspace (`~/.occtmcp-cache/workspace`, `Sources/Script/main.swift`) and stashes the source for `get_script`.
2. Makes a stage directory under the system temp directory, outside the scene, and runs the workspace (`swift build -c release`, then `swift run --skip-build`); only the run, not the build, is given `OCCTSWIFT_OUTPUT_DIR` set to it. That is the variable `ScriptContext` reads; `OCCTMCP_OUTPUT_DIR`, which names the scene, is never exported to the child. Cold start of the underlying SwiftPM workspace is 60+s on first call.
3. Filters noisy OCCT bridge nullability warnings from build output; compiler diagnostics still reach the LLM under the `Script failed.` prefix.
4. Classifies the run (`ExecuteScriptStage.swift`). A non-zero exit fails it; so does `run-failed.json` (`ctx.fail(_:)`) even after an exit of zero; so does a manifest that cannot be read or that lists a file the stage lacks or a name that is not a plain file name. A clean exit with no manifest is a success that changed nothing. A failed run leaves the scene as it was.
5. Promotes a clean run. Once the promotion has succeeded, `SceneHistory` records the scene it replaced, so `compare_versions` has history; a vetoed write or a promoter that threw leaves the history as it was. With a host's `ScriptStagePromoter` the host promotes; otherwise the scene is replaced: the listed files are copied in under names no earlier file has, `manifest.json` is swapped through `ManifestStore.update`, and the files the previous manifest listed are removed. Sidecars such as `annotations.json` are not touched; `provenance.json` is cleared as `clear_scene` clears it.
6. Reads `manifest.json` from the scene and returns it with build output, and removes the stage.

Writing `manifest.json` to the scene is the side effect that matters: `OCCTSwiftViewport`'s `ScriptWatcher` watches that file, so the promotion's manifest swap triggers the live 3D reload. The script's own `emit()` now writes the stage's manifest, which no watcher sees.

The 2 min timeout is per-request.
