#!/usr/bin/env python3
"""Print the revision Package.resolved pins for one dependency identity.

Usage: pinned-revision.py <identity> [Package.resolved]

Exits 1 with a message on stderr when the file or the pin is missing, so a CI step that
consumes the revision fails loudly instead of checking out an empty ref.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    identity = sys.argv[1]
    path = sys.argv[2] if len(sys.argv) == 3 else "Package.resolved"
    try:
        with open(path) as f:
            pins = json.load(f)["pins"]
    except (OSError, ValueError, KeyError) as e:
        print(f"cannot read pins from {path}: {e}", file=sys.stderr)
        return 1
    for pin in pins:
        if pin.get("identity") == identity:
            rev = pin.get("state", {}).get("revision")
            if rev:
                print(rev)
                return 0
    print(f"no pinned revision for '{identity}' in {path}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
