#!/usr/bin/env python3
"""Tests for tools/preprocess.py's #embed directive, which splices a file into
another at build time.
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from preprocess import process_file  # noqa: E402


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
