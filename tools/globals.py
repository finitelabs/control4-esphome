#!/usr/bin/env python3
"""
Fail when a build reads a global its #ifdef/#ifndef branches took away.

A name a branch defines and shared code reads works in the build that keeps the
branch and is nil in the other, which the tests never see: they load the source
with every branch in. So each build's Lua is compared with its source, as LuaJIT
compiles both (tools/globals.lua):

- a global a built file reads that its source never reads as a global was a local
  the build lost, such as a `local function` inside `--#ifndef DRIVERCENTRAL`;
- a global a build reads that the source sets but the build never does was
  defined only in a branch the build left out.

A built file that does not compile fails too. Run after `tools/preprocess.py`, as
`make check` does:
    tools/globals.py build/oss build/drivercentral
"""

from __future__ import annotations

import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TREES = ("src", "drivers", "vendor")


def lua_files(base: Path) -> list[Path]:
    return sorted(p for tree in TREES for p in (base / tree).rglob("*.lua"))


def source_of(built: Path, build_dir: Path, root: Path) -> Path | None:
    """
    The source file a built one came from. A variant's folder, drivers/<driver>_<suffix>,
    came from drivers/<driver>, which holds the variants.json.
    """
    rel = built.relative_to(build_dir)
    source = root / rel
    if source.is_file():
        return source
    if rel.parts[0] != "drivers":
        return None
    variant = rel.parts[1]
    for driver in sorted((root / "drivers").iterdir(), key=lambda d: -len(d.name)):
        if (driver / "variants.json").is_file() and (
            variant == driver.name or variant.startswith(driver.name + "_")
        ):
            candidate = driver.joinpath(*rel.parts[2:])
            return candidate if candidate.is_file() else None
    return None


def globals_of(files: list[Path]) -> tuple[dict, dict]:
    """
    Each file's global reads and sets ({path: {"GGET": set, "GSET": set}}), and the
    compile error of each file LuaJIT could not load.
    """
    found: dict = defaultdict(lambda: {"GGET": set(), "GSET": set()})
    errors: dict = {}
    if not files:
        return found, errors
    run = subprocess.run(
        ["luajit", str(Path(__file__).parent / "globals.lua"), *map(str, files)],
        capture_output=True,
        text=True,
    )
    if run.returncode != 0:
        raise SystemExit(f"Error: tools/globals.lua failed: {run.stderr.strip()}")
    for line in run.stdout.splitlines():
        path, op, name = line.split("\t", 2)
        if op == "ERROR":
            errors[Path(path)] = name
        else:
            found[Path(path)][op].add(name)
    return found, errors


def check(build_dirs: list[Path], root: Path = ROOT) -> list[str]:
    """Each global a build reads that its branches took away, as an error message."""
    problems = []
    for build_dir in build_dirs:
        built = lua_files(build_dir)
        pairs = {b: source_of(b, build_dir, root) for b in built}
        sources = sorted({s for s in pairs.values() if s is not None})
        found, errors = globals_of(built + sources)
        set_in_source = set().union(*(found[s]["GSET"] for s in sources))
        set_in_build = set().union(*(found[b]["GSET"] for b in built))
        only_in_branches = set_in_source - set_in_build
        for b, s in pairs.items():
            if s is None:
                continue
            where = s.relative_to(root)
            if b in errors:
                problems.append(
                    f'File "{where}": the {build_dir.name} build does not compile:'
                    f" {errors[b]}"
                )
                continue
            reads = found[b]["GGET"]
            if s in errors:
                lost = set()
            else:
                lost = reads - found[s]["GGET"]
            for name in sorted(lost):
                problems.append(
                    f'File "{where}": the {build_dir.name} build reads `{name}` as a'
                    " global, but the source declares it local. An #ifdef/#ifndef"
                    " branch this build leaves out holds the declaration."
                )
            for name in sorted((reads & only_in_branches) - lost):
                problems.append(
                    f'File "{where}": the {build_dir.name} build reads the global'
                    f" `{name}`, which only an #ifdef/#ifndef branch this build leaves"
                    " out sets."
                )
    return problems


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 1
    problems = check([Path(a).resolve() for a in argv])
    for problem in problems:
        print(f"Error: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
