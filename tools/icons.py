#!/usr/bin/env python3
"""Export the driver icons from resources/Driver Icons.sketch with Sketch's sketchtool.

Everything lands in dist/icons/, laid out like a driver folder (www/icons/ and
www/documentation/images/) plus cards/ for DriverCentral and the website. Then each
file a driver already has under drivers/*/www/ is refreshed. Needs Sketch.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

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
    print(f"exported to {args.out}/, refreshed {len(refreshed)} files under drivers/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
