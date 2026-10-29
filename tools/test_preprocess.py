#!/usr/bin/env python3
"""Tests for tools/preprocess.py's #embed directive, which splices a file into
another at build time.
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from preprocess import packaged_driver_names, process_file  # noqa: E402


class EmbedDirectiveTest(unittest.TestCase):
    def _process(self, content, frag=None, fragname="frag.xml", conditions=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        d = Path(tmp.name)
        if frag is not None:
            (d / fragname).write_text(frag, encoding="utf-8")
        f = d / "driver.xml"
        f.write_text(content, encoding="utf-8")
        process_file(f, conditions if conditions is not None else {"OSS"})
        return f.read_text(encoding="utf-8")

    def test_embed_expands_the_fragment_inline(self):
        out = self._process(
            "<binding_keys>\n  <!-- #embed frag.xml -->\n</binding_keys>\n",
            frag="  <key>A</key>\n  <key>B</key>\n",
        )
        self.assertIn("<key>A</key>", out)
        self.assertIn("<key>B</key>", out)
        self.assertNotIn("#embed", out)

    def test_directives_inside_the_fragment_are_processed(self):
        frag = "<!-- #ifdef OSS -->\n<oss/>\n<!-- #else -->\n<dc/>\n<!-- #endif -->\n"
        out = self._process(
            "<r>\n<!-- #embed frag.xml -->\n</r>\n", frag=frag, conditions={"OSS"}
        )
        self.assertIn("<oss/>", out)
        self.assertNotIn("<dc/>", out)

    def test_missing_embed_target_is_a_hard_error(self):
        with self.assertRaises(ValueError):
            self._process("<r>\n  <!-- #embed does-not-exist.xml -->\n</r>\n")

    def test_embed_changelog_is_not_swallowed_by_the_generic_handler(self):
        # #embed-changelog is a distinct directive (no space after #embed); it must
        # still resolve against the repo CHANGELOG rather than error as a missing path.
        out = self._process("<r>\n<!-- #embed-changelog -->\n</r>\n")
        self.assertNotIn("#embed-changelog", out)
        self.assertIn("Changelog", out)


class DriverFilenamesDirectiveTest(unittest.TestCase):
    def _process(self, content, driver_names):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        f = Path(tmp.name) / "driver.lua"
        f.write_text(content, encoding="utf-8")
        process_file(f, {"OSS"}, driver_names=driver_names)
        return f.read_text(encoding="utf-8")

    def test_expands_to_one_line_per_packaged_driver(self):
        out = self._process(
            "LIST = {\n  -- #driver-filenames\n}\n", ["hub", "hub_light"]
        )
        self.assertEqual(out, 'LIST = {\n  "hub.c4z",\n  "hub_light.c4z",\n}\n')

    def test_left_in_place_while_the_drivers_are_unknown(self):
        out = self._process("LIST = {\n  -- #driver-filenames\n}\n", None)
        self.assertEqual(out, "LIST = {\n  -- #driver-filenames\n}\n")

    def test_a_leftover_variant_filenames_line_fails_the_build(self):
        with self.assertRaisesRegex(ValueError, "lib.driver-filenames"):
            self._process(
                'LIST = {\n  "hub.c4z",\n  -- #variant-filenames hub_fan\n}\n', ["hub"]
            )

    def test_dropped_with_a_branch_the_build_leaves_out(self):
        out = self._process(
            "--#ifdef DRIVERCENTRAL\nLIST = {\n  -- #driver-filenames\n}\n--#endif\n",
            ["hub"],
        )
        self.assertEqual(out, "")


class PackagedDriverNamesTest(unittest.TestCase):
    def _drivers(self, projects):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        d = Path(tmp.name)
        for name, project in projects.items():
            (d / name).mkdir()
            if project is not None:
                (d / name / "driver.c4zproj").write_text(project, encoding="utf-8")
        return d

    def test_names_come_from_the_project_resolved_for_the_build(self):
        dev = (
            "<!-- #ifdef DRIVERCENTRAL_DEV -->\n"
            '<Driver type="c4z" name="hc_dev">\n'
            "<!-- #else -->\n"
            '<Driver type="c4z" name="hc">\n'
            "<!-- #endif -->\n"
            "</Driver>\n"
        )
        plain = '<Driver type="c4z" name="hc_light" squishLua="true">\n</Driver>\n'
        projects = {"hc": dev, "hc_light": plain, "notes": None}
        self.assertEqual(
            packaged_driver_names(self._drivers(projects), {"DRIVERCENTRAL"}),
            ["hc", "hc_light"],
        )
        self.assertEqual(
            packaged_driver_names(
                self._drivers(projects), {"DRIVERCENTRAL", "DRIVERCENTRAL_DEV"}
            ),
            ["hc_dev", "hc_light"],
        )

    def test_a_project_without_a_name_is_a_hard_error(self):
        d = self._drivers({"hc": '<Driver type="c4z">\n</Driver>\n'})
        with self.assertRaises(ValueError):
            packaged_driver_names(d, {"OSS"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
