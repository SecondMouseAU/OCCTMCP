# References

* [CI and the test gate](ci.md) - What each workflow runs, why path filtering lives in a job, what `ci-gate` is for, and why the Node end-to-end suite stays off the PR path.
* [External dependencies, and what each version floor buys](external-dependencies.md) - Every dependency of both implementations with the reason its floor is where it is, so a bump is a decision rather than a guess.
* [History wiring and selectionId remap](history-and-remap.md) - How a selectionId survives a mutation: the three remap rungs, the per-tool history path, and the identity hazards (instance-scoped UIDs, TShape identity in findNode, enumeration-order labels) that make a remap silently wrong rather than failing.
* [The execute_script template](script-template.md) - The structure every script passed to execute_script must follow, and what each call in it does.
