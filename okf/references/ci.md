---
type: reference
title: CI and the test gate
resource: https://github.com/SecondMouseAU/OCCTMCP/tree/main/.github/workflows
tags: [ci, testing, github-actions]
description: What each workflow runs, why path filtering lives in a job and not on the workflow, what ci-gate is for, and how the Node end-to-end suite is kept off the PR path.
generated: { by: claude-code/sonnet-5, at: 2026-10-07 }
---

# CI and the test gate

| Workflow | Runs | Trigger |
|---|---|---|
| `tests.yml` | `changes`, then `swift` (macos-15: lockfile check, `swift build`, `swift test`, all with `OCCTMCP_FORCE_REMOTE_DEPS=1`), `node` (ubuntu: `npx tsc`, `npm test`), then `ci-gate` | every PR, push to `main`, manual |
| `code-style.yml` | swift-format, SwiftLint, style manifest | PR and push to `main` |
| `integration.yml` | the Node end-to-end suite against a built `occtkit` | nightly and manual only |

## Rules

- **No workflow-level `paths` or `paths-ignore`.** A workflow the filter skips reports no check, so
  a required status would wait forever. The `changes` job classifies the diff and the `swift` and
  `node` jobs hang off it.
- **`ci-gate` is the one check to require on `main`.** It runs `if: always()`, fails on any failed
  or cancelled need, and fails on a skip the `changes` job did not ask for. Give it no `name:` key:
  the rule matches the job id. Require it only after it has reported `success` on `main`'s HEAD.
- **Node CI uses `npx tsc`, not `npm run build`.** The `prebuild` hook regenerates
  `src/api-reference.ts` from `~/Projects/OCCTSwift`, which exists only on a dev machine, and it
  rewrites a committed file.
- **`integration.yml` is not blocking.** It builds `occtkit` from OCCTSwiftScripts on the runner, a
  step that has not yet run green. Until it has, a red there is information, not a merge gate.
- **A tool failure is not a JSON-RPC error.** Integration tests read `result.isError`
  (`expectToolOK` in `IntegrationTests.swift`); `resp["error"] == nil` holds for a failed tool.

See [prove-the-test-fails](../policies/prove-the-test-fails.md) for the rule a new test or CI job
answers to.
