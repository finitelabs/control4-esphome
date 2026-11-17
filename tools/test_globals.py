#!/usr/bin/env python3
"""Tests for tools/globals.py: a global a build's #ifdef branches took away fails."""

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from globals import check  # noqa: E402
from preprocess import process_file  # noqa: E402

BUILDS = {"oss": {"OSS"}, "drivercentral": {"DRIVERCENTRAL"}}


class GlobalsTest(unittest.TestCase):
    def _check(self, files, variants=None):
        """Lay out files under drivers/, preprocess both builds, and check them."""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        for rel, text in files.items():
            path = root / "drivers" / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        for name, suffixes in (variants or {}).items():
            (root / "drivers" / name / "variants.json").write_text(
                json.dumps({"variants": [{"suffix": s} for s in suffixes]})
            )
        dirs = []
        for build, conditions in BUILDS.items():
            out = root / "build" / build
            for rel in files:
                driver, rest = rel.split("/", 1)
                for suffix in (variants or {}).get(driver, [None]):
                    folder = f"{driver}_{suffix}" if suffix else driver
                    dest = out / "drivers" / folder / rest
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(root / "drivers" / rel, dest)
                    process_file(dest, conditions)
            dirs.append(out)
        return check(dirs, root)

    def test_a_local_only_one_build_declares_fails_that_build(self):
        problems = self._check(
            {
                "d/driver.lua": "--#ifndef DRIVERCENTRAL\n"
                "local function ids()\n  return {}\nend\n"
                "--#endif\n"
                "local api = { buttons = ids }\n"
                "return api\n"
            }
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("drivercentral build reads `ids`", problems[0])
        self.assertIn('"drivers/d/driver.lua"', problems[0])

    def test_a_global_only_one_build_sets_fails_the_other(self):
        problems = self._check(
            {
                "d/driver.lua": "--#ifdef DRIVERCENTRAL\n"
                "function Licensed()\n  return true\nend\n"
                "--#endif\n"
                "print(Licensed())\n"
            }
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("oss build reads the global `Licensed`", problems[0])

    def test_a_name_both_branches_declare_passes(self):
        self.assertEqual(
            self._check(
                {
                    "d/driver.lua": "--#ifdef DRIVERCENTRAL\n"
                    "local mode = 'dc'\n"
                    "--#else\n"
                    "local mode = 'oss'\n"
                    "--#endif\n"
                    "print(mode)\n"
                }
            ),
            [],
        )

    def test_a_name_read_only_inside_its_branch_passes(self):
        self.assertEqual(
            self._check(
                {
                    "d/driver.lua": "--#ifndef DRIVERCENTRAL\n"
                    "local function ids()\n  return {}\nend\n"
                    "print(ids())\n"
                    "--#endif\n"
                }
            ),
            [],
        )

    def test_a_variant_is_checked_against_its_driver(self):
        problems = self._check(
            {
                "fan/driver.lua": "--#ifndef DRIVERCENTRAL\n"
                "local speeds = 3\n"
                "--#endif\n"
                "print(speeds)\n"
            },
            variants={"fan": ["1_speed", "2_speed"]},
        )
        self.assertEqual(len(problems), 2)
        self.assertTrue(all('"drivers/fan/driver.lua"' in p for p in problems))

    def test_a_build_that_no_longer_compiles_fails(self):
        problems = self._check(
            {
                "d/driver.lua": "if Ready then\n"
                "--#ifdef DRIVERCENTRAL\n"
                "  print('dc')\n"
                "end\n"
                "--#endif\n"
            }
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("oss build does not compile", problems[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
