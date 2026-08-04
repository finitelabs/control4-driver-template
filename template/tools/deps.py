#!/usr/bin/env python3
"""Verify the venv satisfies requirements.txt.

Subcommands:
  deps.py check <requirements.txt>
      Exit 0 if every requirement (and every requested extra) is installed in
      the interpreter running this script. Otherwise list what is missing and
      exit 1 with the command to fix it.

Why this exists: the $(VENV_STAMP) rule in the Makefile re-installs whenever
requirements.txt changes, which covers dependencies added by a template update.
It cannot see a venv that drifted some other way (a hand-removed package, an
interrupted install, a venv whose python was upgraded out from under it). This
turns that into an actionable message up front instead of an ImportError deep
inside a docs or format step.

Runs on the stdlib only -- it has to work in exactly the broken venv it is
diagnosing.
"""

import re
import sys
from importlib.metadata import PackageNotFoundError, distribution
from pathlib import Path

# name[extra1,extra2]>=1.0 -- version specifiers are deliberately ignored, see
# check() below.
REQUIREMENT = re.compile(r"^(?P<name>[A-Za-z0-9._-]+)(?:\[(?P<extras>[^\]]*)\])?")
# "linkify-it-py (>=1,<3) ; extra == 'linkify'" in a distribution's metadata.
EXTRA_MARKER = re.compile(r"extra\s*==\s*['\"](?P<extra>[^'\"]+)['\"]")


def parse(requirements_path: Path) -> list[tuple[str, list[str]]]:
    """Return [(distribution name, [extras])] from a requirements file."""
    parsed = []
    for raw in requirements_path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        # Skip blanks, pip options (-r, --index-url) and anything guarded by an
        # environment marker: evaluating markers needs `packaging`, which is not
        # guaranteed present, and a wrong guess would block the build.
        if not line or line.startswith("-") or ";" in line:
            continue
        match = REQUIREMENT.match(line)
        if match is None:
            continue
        extras = [e.strip() for e in (match["extras"] or "").split(",") if e.strip()]
        parsed.append((match["name"], extras))
    return parsed


def installed(dist_name: str) -> bool:
    try:
        distribution(dist_name)
    except PackageNotFoundError:
        return False
    return True


def extra_dependencies(dist_name: str, extras: list[str]) -> list[str]:
    """Names a distribution pulls in for the given extras, per its metadata."""
    names = []
    for requirement in distribution(dist_name).requires or []:
        marker = EXTRA_MARKER.search(requirement)
        if marker is None or marker["extra"] not in extras:
            continue
        match = REQUIREMENT.match(requirement.strip())
        if match is not None:
            names.append(match["name"])
    return names


def check(requirements_path: Path) -> int:
    # Presence only, never versions: pip owns resolution, and a version check
    # here could fail a venv pip considers perfectly valid.
    missing = []
    for name, extras in parse(requirements_path):
        if not installed(name):
            missing.append(name)
            # Its extras cannot be resolved without its metadata, and reporting
            # them too would just be noise on top of the real cause.
            continue
        for dependency in extra_dependencies(name, extras):
            if not installed(dependency):
                missing.append(f"{dependency} (via {name}[{','.join(extras)}])")
    if not missing:
        return 0
    print(f"{requirements_path} is not satisfied by {sys.prefix}", file=sys.stderr)
    for name in missing:
        print(f"  missing: {name}", file=sys.stderr)
    print("\nRun `make clean-all && make init` to rebuild the venv.", file=sys.stderr)
    return 1


def main() -> int:
    args = sys.argv[1:]
    cmd, rest = (args[0], args[1:]) if args else ("", [])
    if cmd == "check" and len(rest) == 1:
        return check(Path(rest[0]).resolve())
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
