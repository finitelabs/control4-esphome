#!/usr/bin/env python3
"""Verify the venv satisfies requirements.txt.

Subcommands:
  deps.py check <requirements.txt> [<stamp>]
      Exit 0 if every requirement (and every requested extra) is installed in
      the interpreter running this script. Otherwise list what is missing and
      exit 1 with the command to fix it. <stamp> is the Makefile's install
      stamp; when given, the fix command invalidates it rather than proposing
      a full venv rebuild.

Why this exists: the $(VENV_STAMP) rule in the Makefile re-installs whenever
requirements.txt changes, which covers dependencies added by a template update.
It cannot see a venv that drifted some other way (a hand-removed package, an
interrupted install, a venv whose python was upgraded out from under it). This
turns that into an actionable message up front instead of an ImportError deep
inside a docs or format step.

Runs on the stdlib only -- it has to work in exactly the broken venv it is
diagnosing.
"""

# Keeps PEP 604 annotations (`Path | None`) readable on the documented 3.9
# floor, where they would otherwise raise TypeError at import.
from __future__ import annotations

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
        # A PEP 508 direct reference still names a distribution, so keep what is
        # left of the "@": a distribution name cannot contain one, and PEP 508
        # permits both "name @ https://host/pkg.whl" and the space-less form.
        # A bare URL, VCS ref or filesystem path names nothing: matching its
        # leading token reports "missing: git" for a line pip installs fine, and
        # no amount of reinstalling would fix it.
        head = line.split("@", 1)[0].strip()
        if head.startswith((".", "/", "git+")) or "://" in head:
            continue
        match = REQUIREMENT.match(head)
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
        spec, _, marker = requirement.partition(";")
        # Only a bare `extra == "x"` is actionable. A compound marker such as
        # `extra == "x" and python_version < "3.10"` needs real marker
        # evaluation, which needs `packaging`; treating it as required anyway
        # would report a missing package that is correctly absent and, since
        # check-deps gates build, block the build over it.
        matched_extra = EXTRA_MARKER.fullmatch(marker.strip())
        if matched_extra is None or matched_extra["extra"] not in extras:
            continue
        match = REQUIREMENT.match(spec.strip())
        if match is not None:
            names.append(match["name"])
    return names


def check(requirements_path: Path, stamp_path: Path | None) -> int:
    if not requirements_path.is_file():
        print(f"no such requirements file: {requirements_path}", file=sys.stderr)
        return 2
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
    # Reinstall, do not rebuild: `make clean-all` also removes dist/, taking
    # dist/driverpackager with it, which only a network clone restores.
    # Invalidating the stamp is enough to make `make init` run the install again.
    if stamp_path is not None:
        fix = f"rm -f {stamp_path} && make init"
    elif sys.prefix != sys.base_prefix:
        fix = f"rm -rf {sys.prefix} && make init"
    else:
        # No stamp and not inside a venv, so this was run by hand against the
        # system interpreter. Printing `rm -rf {sys.prefix}` there is a
        # copy-pasteable command that deletes that installation.
        fix = "make init"
    print(f"\nRun `{fix}` to reinstall.", file=sys.stderr)
    return 1


def main() -> int:
    args = sys.argv[1:]
    cmd, rest = (args[0], args[1:]) if args else ("", [])
    if cmd == "check" and len(rest) in (1, 2):
        stamp = Path(rest[1]) if len(rest) == 2 else None
        return check(Path(rest[0]).resolve(), stamp)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
