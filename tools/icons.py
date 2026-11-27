#!/usr/bin/env python3
"""Export the driver icons from resources/Driver Icons.sketch with Sketch's sketchtool.

Everything lands in dist/icons/, laid out like a driver folder (www/icons/ and
www/documentation/images/) plus cards/ for DriverCentral and the website. Each
"State Icon / <id>" artboard's icons land in www/icons/ as <id>_<name>.png. Then each
file a driver already has under drivers/*/www/ is refreshed, and so is the repo-root
documentation/ a root-docs README is built from. The DriverCentral card is also copied
to resources/drivercentral/. Needs Sketch.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from zipfile import ZipFile

SKETCHTOOL = "/Applications/Sketch.app/Contents/Resources/sketchtool/bin/sketchtool"

# Control4's two icon artboards share one name, so they are exported by ID.
ICON_ARTBOARDS = {
    "shaped": "0362998B-27D8-4F37-89B8-5831E90F6779",
    "square": "6F1BF787-D38E-4F93-A465-ACE3C57FFE75",
}

FRAMES = {
    "Documentation Header": "www/documentation/images/header.png",
    "Driver Central Driver Card": "cards/Driver Central Driver Card.png",
    "Website Card - Light": "cards/Website Card - Light.png",
    "Website Card - Dark": "cards/Website Card - Dark.png",
}

# A state icon's artboard holds a copy of the icon group, with the same export formats.
STATE_PREFIX = "State Icon / "


def export(sketchtool: str, args: list[str], out: Path) -> list[Path]:
    out.mkdir(parents=True)
    subprocess.run(
        [
            sketchtool,
            "export",
            *args,
            f"--output={out}",
            "--overwriting=YES",
            # Sketch 2026 turns trimming on when it opens an older file, which crops icons.
            "--trimmed=NO",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return sorted(out.rglob("*.png"))


def state_icons(sketch: Path) -> dict[str, list[str]]:
    """The IDs of the exportable layers in each state artboard, by state."""
    states: dict[str, list[str]] = {}
    with ZipFile(sketch) as z:
        for name in z.namelist():
            if not name.startswith("pages/"):
                continue
            for layer in json.loads(z.read(name)).get("layers", []):
                if layer["name"].startswith(STATE_PREFIX):
                    states[layer["name"][len(STATE_PREFIX) :].strip()] = [
                        child["do_objectID"]
                        for child in layer.get("layers", [])
                        if child.get("exportOptions", {}).get("exportFormats")
                    ]
    return states


def place(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dest)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--sketch", type=Path, default=Path("resources/Driver Icons.sketch")
    )
    parser.add_argument("--style", choices=sorted(ICON_ARTBOARDS), default="shaped")
    parser.add_argument("--out", type=Path, default=Path("dist/icons"))
    parser.add_argument("--drivers", type=Path, default=Path("drivers"))
    parser.add_argument("--root", type=Path, default=Path("."))
    args = parser.parse_args(argv)

    sketchtool = os.environ.get("SKETCHTOOL", SKETCHTOOL)
    if not Path(sketchtool).is_file():
        print(
            f"make icons needs Sketch: no sketchtool at {sketchtool}"
            " (set SKETCHTOOL to point at it)",
            file=sys.stderr,
        )
        return 1
    if not args.sketch.is_file():
        print(f"no {args.sketch}", file=sys.stderr)
        return 1

    shutil.rmtree(args.out, ignore_errors=True)
    with tempfile.TemporaryDirectory() as tmp:
        icons = export(
            sketchtool,
            ["layers", str(args.sketch), f"--item={ICON_ARTBOARDS[args.style]}"],
            Path(tmp, "icons"),
        )
        if not icons:
            print(f"no {args.style} icon artboard in {args.sketch}", file=sys.stderr)
            return 1
        for png in icons:
            # Named after the artboard: "<artboard>/ experience_1024.png".
            place(png, args.out / "www/icons" / png.name.strip())
        for state, items in sorted(state_icons(args.sketch).items()):
            found = []
            if items:
                found = export(
                    sketchtool,
                    ["layers", str(args.sketch), f"--items={','.join(items)}"],
                    Path(tmp, f"state-{state}"),
                )
            if not found:
                print(f"skipped state icon {state}: nothing in it to export")
            for png in found:
                place(png, args.out / "www/icons" / f"{state}_{png.name.strip()}")
        for i, (frame, dest) in enumerate(FRAMES.items()):
            found = export(
                sketchtool,
                ["artboards", str(args.sketch), f"--items={frame}"]
                + ["--formats=png", "--scales=1"],
                Path(tmp, f"frame-{i}"),
            )
            if found:
                place(found[0], args.out / dest)
            else:
                print(f"skipped {frame}: not in {args.sketch}")

    refreshed = []
    for src in sorted((args.out / "www").rglob("*.png")):
        for driver in sorted(p for p in args.drivers.glob("*") if p.is_dir()):
            dest = driver / src.relative_to(args.out)
            if dest.is_file():
                shutil.copyfile(src, dest)
                refreshed.append(dest)
        root = args.root / src.relative_to(args.out / "www")
        if root.is_file():
            shutil.copyfile(src, root)
            refreshed.append(root)
    card = args.out / FRAMES["Driver Central Driver Card"]
    committed = args.root / "resources/drivercentral/product-card-300x300.png"
    if card.is_file() and committed.parent.is_dir():
        shutil.copyfile(card, committed)
        refreshed.append(committed)
    print(f"exported to {args.out}/, refreshed {len(refreshed)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
