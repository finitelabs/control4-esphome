#!/usr/bin/env python3
"""Tests for tools/package.py's check-encrypted, which `make package` runs on every
build that must ship its Lua encrypted.
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
from package import check_encrypted  # noqa: E402

ENCRYPTED_XML = '<devicedata><config><script encryption="2" file="driver.lua" jit="1"/></config></devicedata>'
PLAIN_XML = (
    '<devicedata><config><script file="driver.lua" jit="1"/></config></devicedata>'
)


class CheckEncryptedTest(unittest.TestCase):
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

    def _check(self, build):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = check_encrypted(build)
        return code, err.getvalue()

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
