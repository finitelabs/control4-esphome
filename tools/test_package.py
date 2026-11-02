#!/usr/bin/env python3
"""Tests for tools/package.py's checks: check-encrypted, which `make package` runs on
every build that must ship its Lua encrypted, and the tag version and post-build
checks CI runs.
"""

import contextlib
import io
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from package import (  # noqa: E402
    check_encrypted,
    check_pdfs,
    check_version,
    tag_version,
)

ENCRYPTED_XML = '<devicedata><config><script encryption="2" file="driver.lua" jit="1"/></config></devicedata>'
PLAIN_XML = (
    '<devicedata><config><script file="driver.lua" jit="1"/></config></devicedata>'
)


class InTempDir(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cwd = os.getcwd()
        os.chdir(tmp.name)
        self.addCleanup(os.chdir, cwd)

    def _package(self, build, members, name="probe.c4z"):
        c4z = Path("dist") / build / "c4z"
        c4z.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(c4z / name, "w") as zf:
            for member, text in members.items():
                zf.writestr(member, text)

    def _run(self, fn, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = fn(*args)
        return code, out.getvalue(), err.getvalue()


class CheckEncryptedTest(InTempDir):
    def _check(self, build):
        code, _, err = self._run(check_encrypted, build)
        return code, err

    def test_an_encrypted_driverCentral_package_passes(self):
        self._package(
            "drivercentral", {"driver.xml": ENCRYPTED_XML, "driver.lua.encrypted": "x"}
        )
        self.assertEqual(self._check("drivercentral"), (0, ""))

    def test_a_driverCentral_package_with_plain_lua_fails(self):
        self._package(
            "drivercentral", {"driver.xml": ENCRYPTED_XML, "driver.lua": "print(1)"}
        )
        code, err = self._check("drivercentral")
        self.assertEqual(code, 1)
        self.assertIn("no driver.lua.encrypted", err)
        self.assertIn("holds driver.lua in plain text", err)

    def test_a_driver_xml_that_does_not_ask_for_encryption_fails(self):
        self._package(
            "drivercentral-dev", {"driver.xml": PLAIN_XML, "driver.lua.encrypted": "x"}
        )
        code, err = self._check("drivercentral-dev")
        self.assertEqual(code, 1)
        self.assertIn("does not ask for encryption", err)

    def test_a_script_tag_inside_a_comment_does_not_count(self):
        xml = '<devicedata><config><!-- <script encryption="2" file="driver.lua"/> --><script file="driver.lua"/></config></devicedata>'
        self._package("drivercentral", {"driver.xml": xml, "driver.lua.encrypted": "x"})
        code, err = self._check("drivercentral")
        self.assertEqual(code, 1)
        self.assertIn("does not ask for encryption", err)

    def test_a_driverCentral_build_with_no_package_fails(self):
        (Path("dist") / "drivercentral" / "c4z").mkdir(parents=True)
        code, err = self._check("drivercentral")
        self.assertEqual(code, 1)
        self.assertIn("no package to check", err)

    def test_an_oss_build_preprocess_encrypted_is_checked(self):
        (Path("build") / "oss").mkdir(parents=True)
        (Path("build") / "oss" / ".encrypted").write_text(
            "Encrypted: build secrets were substituted.\n"
        )
        self._package("oss", {"driver.xml": PLAIN_XML, "driver.lua": "print(1)"})
        self.assertEqual(self._check("oss")[0], 1)

    def test_a_plain_oss_build_is_left_alone(self):
        self._package("oss", {"driver.xml": PLAIN_XML, "driver.lua": "print(1)"})
        self.assertEqual(self._check("oss"), (0, ""))


class TagVersionTest(InTempDir):
    def test_a_date_tag_gives_its_date(self):
        self.assertEqual(
            self._run(tag_version, "v20261101")[:2], (0, "DRIVER_VERSION=20261101\n")
        )

    def test_a_suffixed_tag_gives_its_date(self):
        self.assertEqual(
            self._run(tag_version, "v20260918-rc1")[:2],
            (0, "DRIVER_VERSION=20260918\n"),
        )

    def test_a_tag_that_is_not_a_date_fails(self):
        for tag in (
            "20261101",
            "v2026110",
            "v202611011",
            "v20261301",
            "v20261100",
            "v20261132",
            "v20261101-",
            "v20261101rc1",
            "release-v20261101",
        ):
            with self.subTest(tag=tag):
                code, out, err = self._run(tag_version, tag)
                self.assertEqual((code, out), (1, ""))
                self.assertIn("is not vYYYYMMDD", err)


class CheckPdfsTest(InTempDir):
    def test_a_pdf_passes(self):
        docs = Path("dist") / "oss" / "docs"
        docs.mkdir(parents=True)
        (docs / "Example Documentation.pdf").write_bytes(b"%PDF")
        self.assertEqual(self._run(check_pdfs, "oss")[0], 0)

    def test_no_pdf_fails(self):
        docs = Path("dist") / "oss" / "docs"
        docs.mkdir(parents=True)
        (docs / "index.html").write_text("")
        code, _, err = self._run(check_pdfs, "oss")
        self.assertEqual(code, 1)
        self.assertIn("dist/oss/docs has no PDF", err)

    def test_no_docs_folder_fails(self):
        self.assertEqual(self._run(check_pdfs, "oss")[0], 1)


def version_xml(version):
    return f"<devicedata><version>{version}</version></devicedata>"


class CheckVersionTest(InTempDir):
    def test_every_package_at_the_version_passes(self):
        self._package("oss", {"driver.xml": version_xml("20261101")}, "a.c4z")
        self._package("oss", {"driver.xml": version_xml("20261101")}, "b.c4z")
        self.assertEqual(self._run(check_version, "oss", "20261101")[0], 0)

    def test_a_package_at_another_version_fails(self):
        self._package("oss", {"driver.xml": version_xml("20261101")}, "a.c4z")
        self._package("oss", {"driver.xml": version_xml("20261031")}, "b.c4z")
        code, _, err = self._run(check_version, "oss", "20261101")
        self.assertEqual(code, 1)
        self.assertIn("b.c4z has driver version '20261031', expected '20261101'", err)
        self.assertNotIn("a.c4z", err)

    def test_a_package_with_no_version_fails(self):
        self._package("oss", {"driver.xml": "<devicedata><version/></devicedata>"})
        self.assertEqual(self._run(check_version, "oss", "20261101")[0], 1)

    def test_a_package_with_no_driver_xml_fails(self):
        self._package("oss", {"driver.lua": "print(1)"})
        self.assertEqual(self._run(check_version, "oss", "20261101")[0], 1)

    def test_no_package_fails(self):
        (Path("dist") / "oss" / "c4z").mkdir(parents=True)
        self.assertEqual(self._run(check_version, "oss", "20261101")[0], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
