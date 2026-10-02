---
type: reference
title: The execute_script template
resource: https://github.com/SecondMouseAU/OCCTMCP/blob/main/Sources/OCCTMCPCore/Tools/ExecuteScriptTool.swift
tags: [reference, execute-script, template, scriptharness]
description: The structure every script passed to execute_script must follow, and what each call in it does.
generated: { by: human:gsdali, at: 2026-09-06 }
---

# The execute_script template

Scripts passed to `execute_script` must follow this structure:

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

// ... create geometry using OCCTSwift API ...

try ctx.add(shape, id: "part", color: C.steel, name: "My Part")
try ctx.emit(description: "Description of the model")
```
