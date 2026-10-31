#!/usr/bin/env python3
"""Tests for tools/support_code.py's code and for where a build secret is read
from (tools/preprocess.py's build_secret).
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import preprocess  # noqa: E402
from support_code import code_for  # noqa: E402

# The same secret and days as test/test_support_code.lua, so the two computations cannot drift apart.
SECRET = "0123456789abcdef0123456789abcdef"


class CodeTest(unittest.TestCase):
    def test_the_days_code_matches_the_library(self):
        self.assertEqual(code_for(SECRET, "2026-10-31"), "VEAFA-RSBWM")
        self.assertEqual(code_for(SECRET, "2026-11-01"), "0GE0Q-Z00XP")
        self.assertEqual(code_for(SECRET, "2026-10-30"), "WYYNC-BTR1V")


class OnlyDriverCentralBuildsCarryTheSecretTest(unittest.TestCase):
    def _preprocessed(self, conditions):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        lib = Path(tmp.name) / "support-code.lua"
        shutil.copy(
            Path(__file__).parent.parent / "src" / "lib" / "support-code.lua", lib
        )
        preprocess.process_file(lib, conditions)
        return lib.read_text(encoding="utf-8")

    def test_a_drivercentral_build_keeps_the_placeholder_to_substitute(self):
        self.assertIn(
            '"__SUPPORT_CODE_SECRET__"', self._preprocessed({"DRIVERCENTRAL"})
        )

    def test_an_oss_build_has_no_placeholder_so_is_neither_given_nor_encrypted_for_it(
        self,
    ):
        self.assertNotIn("SUPPORT_CODE_SECRET", self._preprocessed({"OSS"}))


class BuildSecretTest(unittest.TestCase):
    def _keychain(self, stdout="from-keychain\n", returncode=0):
        found = subprocess.CompletedProcess([], returncode, stdout=stdout, stderr="")
        return mock.patch.object(preprocess.subprocess, "run", return_value=found)

    def test_the_environment_comes_first(self):
        with mock.patch.dict(os.environ, {"S": "from-env"}), self._keychain() as run:
            self.assertEqual(
                preprocess.build_secret("S", {"S": "from-dotenv"}), "from-env"
            )
            run.assert_not_called()

    def test_then_dotenv(self):
        with mock.patch.dict(os.environ, {}, clear=True), self._keychain() as run:
            self.assertEqual(
                preprocess.build_secret("S", {"S": "from-dotenv"}), "from-dotenv"
            )
            run.assert_not_called()

    def test_then_the_keychain_on_macos(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            preprocess.sys, "platform", "darwin"
        ), self._keychain() as run:
            self.assertEqual(preprocess.build_secret("S", {}), "from-keychain")
            self.assertEqual(
                run.call_args.args[0],
                [
                    "security",
                    "find-generic-password",
                    "-s",
                    "control4-driver-build",
                    "-a",
                    "S",
                    "-w",
                ],
            )

    def test_a_missing_keychain_item_is_empty(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            preprocess.sys, "platform", "darwin"
        ), self._keychain(stdout="", returncode=44):
            self.assertEqual(preprocess.build_secret("S", {}), "")

    def test_no_keychain_off_macos(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            preprocess.sys, "platform", "linux"
        ), self._keychain() as run:
            self.assertEqual(preprocess.build_secret("S", {}), "")
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
