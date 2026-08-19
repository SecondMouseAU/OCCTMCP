#!/usr/bin/env python3
"""Enforce "if you touch a legacy file, you fix it" for the code-style rollout (#173).

A whole-tree zero-tolerance swift-format/SwiftLint gate would fail every PR against the
~5,400 pre-existing swift-format diagnostics already measured across Sources/ on rollout
day (never run through the tool before). Forcing a big-bang fix before any gate can turn
on is the outcome the ecosystem's rollout plan explicitly rejected in favor of a gradual
rollout: fix what you touch, not the whole tree at once. Logic here is unchanged from the
OCCTSwift rollout's own already-debugged version (#876); see that repo's copy of this
script for the C++-bridge-layer variant; this repo has no first-party bridge code, so only
one manifest exists here.

One manifest file holds the exemption list, seeded once on rollout day with every file
that existed then:
  - scripts/style-manifest-swift.txt   (Sources/**/*.swift)

The rule, checked against the PR's diff relative to a base ref (`origin/main` by
default):
  1. A file NOT on the manifest must already be clean (checked separately, by the
     normal swift-format/swiftlint gate steps; this script doesn't re-run those
     tools, it only enforces the manifest's own bookkeeping).
  2. A file ON the manifest that appears in the diff must be REMOVED from the manifest
     in the same PR. Leaving it listed while touching it is exactly what this script
     exists to catch: "touched a legacy file, left it on the exemption list" is a
     silent failure to comply, not a clean pass.
  3. The manifest may only shrink. Comparing HEAD's manifest against the base ref's, any
     entry present at HEAD but absent at the base is a new grandfather-listing, which
     this policy doesn't allow: everything new complies from creation.

Migration carve-out (#177): a cross-repo dependency migration (a repin like the
OCCTSwift 3.0.0 bump, #176) can be FORCED by the compiler to touch a manifest-listed
file it did not choose and has no reason to bring into full compliance in the same PR:
that would bury the semantic change under an unrelated reformat diff. A commit in the
PR whose message carries a trailer

  Style-Manifest-Carveout: <reason, must cite a tracking issue, e.g. "repin, see #176">

downgrades rule 2 from FAIL to WARN for this run: touched-but-not-removed files are
still reported, but named as a declared carve-out rather than a violation. Rule 3 (the
manifest may only shrink) is NOT covered by the carve-out: a migration has no reason
to add new exemptions, only to leave existing ones un-remediated for one more PR. The
trailer must be added deliberately per PR; there is no blanket bypass and no CI workflow
edit required. See okf/policies/code-style.md#migration-carve-out.

Usage:
  scripts/check-style-manifest.py                # compares against origin/main
  scripts/check-style-manifest.py --base <ref>
  scripts/check-style-manifest.py --self-test
"""
import argparse
import re
import subprocess
import sys

MANIFESTS = [
    'scripts/style-manifest-swift.txt',
]

CARVEOUT_TRAILER = 'Style-Manifest-Carveout'
CARVEOUT_TRAILER_RE = re.compile(rf'^{CARVEOUT_TRAILER}:\s*(.+)$')
CARVEOUT_ISSUE_RE = re.compile(r'#\d+')


def run(args):
    return subprocess.run(args, capture_output=True, text=True, check=False)


def read_manifest_at(ref, path):
    """The manifest's contents at `ref` ('' for the working tree), as a set of paths,
    or None if the file doesn't exist at that ref.

    None vs. an empty set matters: a manifest that doesn't exist yet at the base ref is
    being seeded by this PR (fine, not a shrink violation); a manifest that exists and
    is empty has genuinely had every entry removed (also fine, same reason). Collapsing
    the two to "empty set" is exactly the bug this distinction exists to avoid; it's
    what made this script fail against its own seeding PR on first real-git-history run
    (#876), since every entry in a brand-new manifest read as "newly added" relative to
    a base where the file didn't exist at all.
    """
    if ref == '':
        try:
            with open(path, encoding='utf-8') as fh:
                lines = fh.read().splitlines()
        except FileNotFoundError:
            return None
    else:
        result = run(['git', 'show', f'{ref}:{path}'])
        if result.returncode != 0:
            return None
        lines = result.stdout.splitlines()
    return {line.strip() for line in lines if line.strip() and not line.strip().startswith('#')}


def diff_files(base):
    result = run(['git', 'diff', '--name-only', f'{base}...HEAD'])
    if result.returncode != 0:
        print(f'FAIL: git diff against {base} failed: {result.stderr.strip()}', file=sys.stderr)
        sys.exit(2)
    return set(result.stdout.splitlines())


def extract_carveout_reason(commit_bodies):
    """Pure logic: given a list of commit message bodies (newest-first or any order),
    return the first `Style-Manifest-Carveout: <reason>` trailer value that cites a
    tracking issue (`#NNN`), or None.

    A trailer present but missing an issue reference is treated as absent, not
    accepted: an untracked carve-out is indistinguishable from someone waving past the
    gate with no record of why, which defeats the whole point of making this
    mechanical rather than verbal.
    """
    for body in commit_bodies:
        for line in body.splitlines():
            m = CARVEOUT_TRAILER_RE.match(line.strip())
            if m and CARVEOUT_ISSUE_RE.search(m.group(1)):
                return m.group(1).strip()
    return None


def find_carveout_reason(base):
    """extract_carveout_reason(...) over every commit in `base..HEAD`."""
    result = run(['git', 'log', f'{base}..HEAD', '--format=%B%x00'])
    if result.returncode != 0:
        return None
    return extract_carveout_reason(result.stdout.split('\x00'))


def check(manifest_path, base, changed):
    """Pure logic: given one manifest's base/HEAD contents and the PR's changed-file
    set, return (touched_but_not_removed, newly_added). Both should be empty to pass.
    """
    base_entries = read_manifest_at(base, manifest_path)
    head_entries = read_manifest_at('', manifest_path) or set()

    touched_but_not_removed = sorted(head_entries & changed)
    # base_entries is None exactly when the manifest doesn't exist at the base ref yet:
    # this PR is seeding it, not growing an existing one. Nothing to compare against,
    # so nothing counts as "newly added"; see read_manifest_at's own docstring.
    newly_added = [] if base_entries is None else sorted(head_entries - base_entries)
    return touched_but_not_removed, newly_added


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--base', default='origin/main', help='ref to diff against (default: origin/main)')
    ap.add_argument('--self-test', action='store_true')
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    changed = diff_files(args.base)
    carveout_reason = find_carveout_reason(args.base)
    fail = False
    for manifest_path in MANIFESTS:
        touched, added = check(manifest_path, args.base, changed)
        if touched and carveout_reason:
            print(f'WARN: {manifest_path} still lists {len(touched)} file(s) this PR touches, '
                  f'carved out ({carveout_reason}):')
            for f in touched:
                print(f'  {f}')
            print('  Not remediated in this PR under the declared migration carve-out '
                  '(okf/policies/code-style.md#migration-carve-out). File or update the '
                  'tracked sweep issue if one does not already cover these.')
        elif touched:
            fail = True
            print(f'FAIL: {manifest_path} still lists {len(touched)} file(s) this PR touches:')
            for f in touched:
                print(f'  {f}')
            print('  Bring each into compliance (swift-format/swiftlint/clang-format clean) '
                  'and remove it from the manifest in this same PR, or add a '
                  f'"{CARVEOUT_TRAILER}: <reason, citing a tracking issue>" commit trailer '
                  'if this is a forced cross-repo migration (okf/policies/code-style.md'
                  '#migration-carve-out).')
        if added:
            fail = True
            print(f'FAIL: {manifest_path} grew by {len(added)} entr{"y" if len(added) == 1 else "ies"} '
                  f'not present at {args.base}:')
            for f in added:
                print(f'  {f}')
            print('  New files comply from creation; they do not get grandfathered onto the manifest.')

    if not fail:
        suffix = f' (carve-out active: {carveout_reason})' if carveout_reason else ''
        print(f'check-style-manifest: clean against {args.base}{suffix}')
    return 1 if fail else 0


def self_test():
    """Exercise check() against synthetic manifest snapshots, no real git repo needed."""
    import unittest.mock as mock

    cases = [
        ('untouched legacy file, left alone',
         {'A.swift', 'B.swift'}, {'A.swift', 'B.swift'}, set(),
         [], []),
        ('legacy file touched and removed from the manifest (the compliant fix)',
         {'A.swift', 'B.swift'}, {'B.swift'}, {'A.swift'},
         [], []),
        ('legacy file touched, left on the manifest (the violation this script exists for)',
         {'A.swift', 'B.swift'}, {'A.swift', 'B.swift'}, {'A.swift'},
         ['A.swift'], []),
        ('new file grandfathered onto the manifest (not allowed)',
         {'A.swift'}, {'A.swift', 'C.swift'}, set(),
         [], ['C.swift']),
        ('both violations at once',
         {'A.swift', 'B.swift'}, {'A.swift', 'B.swift', 'C.swift'}, {'A.swift'},
         ['A.swift'], ['C.swift']),
        ('manifest does not exist at base: this PR is seeding it, not growing it (#876)',
         None, {'A.swift', 'B.swift', 'C.swift'}, set(),
         [], []),
    ]

    failed = 0
    for name, base_set, head_set, changed, want_touched, want_added in cases:
        with mock.patch.object(sys.modules[__name__], 'read_manifest_at',
                                side_effect=lambda ref, path, b=base_set, h=head_set:
                                h if ref == '' else b):
            touched, added = check('fake-manifest.txt', 'fake-base', changed)
        ok = touched == want_touched and added == want_added
        failed += not ok
        print(f'  {"ok  " if ok else "MISS"} {name}: touched={touched} added={added}')

    print(f'{len(cases) - failed}/{len(cases)} cases correct')

    carveout_cases = [
        ('no trailer at all',
         ['chore: repin OCCTSwift to 3.0.0\n\nSome body text.\n'],
         None),
        ('trailer present, cites an issue',
         ['chore: repin OCCTSwift to 3.0.0\n\nStyle-Manifest-Carveout: cross-repo repin, see #176\n'],
         'cross-repo repin, see #176'),
        ('trailer present, no issue reference: treated as absent',
         ['chore: repin OCCTSwift to 3.0.0\n\nStyle-Manifest-Carveout: trust me\n'],
         None),
        ('trailer on an earlier commit in a multi-commit PR, still found',
         ['fix: typo\n', 'chore: repin\n\nStyle-Manifest-Carveout: repin, see #176\n', 'docs: note\n'],
         'repin, see #176'),
        ('unrelated trailer with the same shape is not mistaken for this one',
         ['fix: typo\n\nSigned-off-by: someone <someone@example.com>\n'],
         None),
    ]
    for name, commit_bodies, want in carveout_cases:
        got = extract_carveout_reason(commit_bodies)
        ok = got == want
        failed += not ok
        print(f'  {"ok  " if ok else "MISS"} {name}: got={got!r}')

    print(f'{len(cases) + len(carveout_cases) - failed}/{len(cases) + len(carveout_cases)} '
          'cases correct')
    return 1 if failed else 0


if __name__ == '__main__':
    import os
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    sys.exit(main())
