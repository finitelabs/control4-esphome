#!/usr/bin/env python3
"""Tests for tools/package.py's checks: check-encrypted, which `make package` runs on
every build that must ship its Lua encrypted, check-sort-order, which `make check`
runs on every driver.xml, and the tag version and post-build checks CI runs.
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
    check_sort_order,
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
            "drivercentral", {"driver.xml": PLAIN_XML, "driver.lua.encrypted": "x"}
        )
        code, err = self._check("drivercentral")
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

    def test_a_folder_given_is_checked_in_place_of_dist(self):
        self._package(
            "drivercentral", {"driver.xml": ENCRYPTED_XML, "driver.lua.encrypted": "x"}
        )
        release = Path("release") / "c4z"
        release.mkdir(parents=True)
        with zipfile.ZipFile(release / "probe.c4z", "w") as zf:
            zf.writestr("driver.xml", ENCRYPTED_XML)
            zf.writestr("driver.lua.encrypted", "x")
            zf.writestr("driver.lua", "print(1)")
        code, _, err = self._run(check_encrypted, "drivercentral", str(release))
        self.assertEqual(code, 1)
        self.assertIn("holds driver.lua in plain text", err)

    def test_an_empty_folder_given_fails(self):
        Path("release").mkdir()
        code, _, err = self._run(check_encrypted, "drivercentral", "release")
        self.assertEqual(code, 1)
        self.assertIn("release has no package to check", err)


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


class CheckSortOrderTest(InTempDir):
    def _xml(self, *orders, name="driver.xml"):
        body = "".join(
            f"<conditional><id>{i}</id><name>C{i}</name>{order}</conditional>"
            for i, order in enumerate(orders, 1)
        )
        Path(name).write_text(
            f"<devicedata><!-- #ifdef DRIVERCENTRAL --><conditionals>{body}</conditionals>"
            "<!-- #endif --></devicedata>"
        )
        return name

    def _check(self, *paths):
        code, _, err = self._run(check_sort_order, list(paths))
        return code, err

    def test_every_conditional_with_its_own_sort_order_passes(self):
        path = self._xml("<sort_order>2</sort_order>", "<sort_order> 1 </sort_order>")
        self.assertEqual(self._check(path), (0, ""))

    def test_a_driver_xml_with_no_conditionals_passes(self):
        Path("driver.xml").write_text("<devicedata><name>x</name></devicedata>")
        self.assertEqual(self._check("driver.xml"), (0, ""))

    def test_a_conditional_without_a_sort_order_fails(self):
        code, err = self._check(self._xml("<sort_order>1</sort_order>", ""))
        self.assertEqual(code, 1)
        self.assertIn("conditional C2 has no whole-number <sort_order>", err)

    def test_a_sort_order_that_is_not_a_whole_number_fails(self):
        code, err = self._check(self._xml("<sort_order>first</sort_order>"))
        self.assertEqual(code, 1)
        self.assertIn("conditional C1 has no whole-number <sort_order>", err)

    def test_two_conditionals_sharing_a_sort_order_fail(self):
        path = self._xml("<sort_order>1</sort_order>", "<sort_order>1</sort_order>")
        code, err = self._check(path)
        self.assertEqual(code, 1)
        self.assertIn("conditional C2 has <sort_order>1, as C1 does", err)

    def test_a_sort_order_up_to_1000_passes(self):
        path = self._xml("<sort_order>1000</sort_order>")
        self.assertEqual(self._check(path), (0, ""))

    def test_a_sort_order_above_1000_fails(self):
        code, err = self._check(self._xml("<sort_order>1001</sort_order>"))
        self.assertEqual(code, 1)
        self.assertIn("conditional C1 has <sort_order>1001, above 1000", err)

    def test_each_driver_xml_is_checked_on_its_own(self):
        a = self._xml("<sort_order>1</sort_order>", name="a.xml")
        b = self._xml("<sort_order>1</sort_order>", "", name="b.xml")
        code, err = self._check(a, b)
        self.assertEqual(code, 1)
        self.assertNotIn("a.xml", err)
        self.assertIn("b.xml: conditional C2", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
