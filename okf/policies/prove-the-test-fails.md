---
type: policy
title: Prove the test fails
description: A passing test is worth nothing until you have watched it fail. Inject the defect it exists to catch, confirm the failure, restore, and report both results in the PR.
tags: [policy, testing, ci, agents]
generated: { by: claude-code/sonnet-5, at: 2026-10-07 }
---

# Prove the test fails

**Every new or changed test is run once with its subject broken.** Inject the defect the test
exists to catch, confirm it fails, restore, confirm it passes. Report both results in the PR, not
just the green one. The same rule applies to a CI job: break its input on a throwaway branch and
watch `ci-gate` go red.

The canonical text is
[`prove-the-test-fails.md` in OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift/blob/main/okf/policies/prove-the-test-fails.md).
It is not yet in the ecosystem hub, so this page is a pointer and restates only what a reviewer
here needs. Change the rule in the canonical repo, not here.

## What this repo adds

- A test that loops over rows (`for row in rows { #expect(...) }`) must first assert the row count,
  or an empty result passes it.
- A negative-only assertion (`!text.contains(...)`) needs a positive one beside it.
- A test whose fixture cannot trigger the guarded behaviour (a closed box under the slippage
  sample floor, say) proves nothing. Assert the precondition before relying on it.
- A green removal run is ambiguous: the guard does nothing, or another guard stands in front of it.
  Say which, and why, in the PR.
- Use a throwaway worktree for the injection. `git stash` is repo-wide, not per-worktree.

## In the PR

The PR template carries a "Proven to fail" row: name the defect injected, the failing output, and
the restored green run. `n/a: <reason>` is allowed, an empty row is not.
