#!/usr/bin/env python3
"""Doctor: feste Ursachen, Fähigkeiten und keinerlei Clipboard-Operationen."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

from lib.runtime import stage_runtime

MOCK = r"""import os
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "uname":
    print(os.environ["MOCK_PLATFORM"])
    sys.exit()
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(f"{name} {args!r}\n")
if name in ("clipboard-undo", "clipboard-undo-linux.py"):
    if args == ["status"]:
        print('{"version":1,"undo_available":false,"pending_valid":false}')
        sys.exit(2 if os.environ.get("MOCK_STATUS_FAIL") else 0)
    if args != ["diagnose"]:
        sys.exit(91)
    if os.environ.get("MOCK_DIAG_FAIL"):
        print("PRIVATE-ERROR", file=sys.stderr)
        sys.exit(2)
    print(os.environ.get("MOCK_DIAG", "ok"))
    sys.exit()
if name == "pandoc":
    if "--version" in args:
        print('pandoc "quoted"\\version\tcontrol')
        sys.exit(1 if os.environ.get("MOCK_PANDOC_FAIL") else 0)
    if "--list-input-formats" in args:
        print("html" if os.environ.get("MOCK_NO_RTF") else "html\nrtf")
        sys.exit()
    if os.environ.get("MOCK_NO_SANDBOX"):
        sys.exit(2)
    if any("lua-filter" in arg for arg in args) and os.environ.get("MOCK_NO_FILTER"):
        sys.exit(2)
    sys.stdin.buffer.read()
    sys.exit()
if name == "perl":
    print("5.34.0")
    sys.exit()
if name == "python3":
    print("Python 3.12")
    sys.exit()
if args in (["--version"], ["-version"]):
    print("mock 1.0")
    sys.exit()
print("PRIVATE-CLIPBOARD-CONTENT")
sys.exit(91)
"""

MOCK_TOOLS = (
    "uname",
    "pandoc",
    "perl",
    "python3",
    "pbpaste",
    "pbcopy",
    "xclip",
    "wl-paste",
    "wl-copy",
    "textutil",
    "iconv",
    "clipboard-html",
    "clipboard-rtf",
    "clipboard-undo",
    "clipboard-undo-linux.py",
)


class DoctorTestCase(unittest.TestCase):
    platform = "Linux"
    wayland_display = ""

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="md-clip-doctor-")
        self.addCleanup(directory.cleanup)
        self.base = Path(directory.name)
        self.runtime = self.base / "bin"
        self.runtime.mkdir()
        stage_runtime(self.runtime)
        for name in MOCK_TOOLS:
            path = self.runtime / name
            path.write_text(f"#!{sys.executable}\n{MOCK}")
            path.chmod(0o755)
        # Fehlende Dependencies dürfen nicht aus dem Host-PATH nachrücken.
        for name in ("bash", "dirname", "basename", "readlink", "head", "tr", "grep"):
            (self.runtime / name).symlink_to(shutil.which(name))
        self.log = self.base / "calls"
        self.env = dict(
            os.environ,
            PATH=str(self.runtime),
            MOCK_LOG=str(self.log),
            MOCK_PLATFORM=self.platform,
            WAYLAND_DISPLAY=self.wayland_display,
        )

    def run_doctor(self, *, json_mode=True, **environment):
        self.log.write_text("")
        command = [str(self.runtime / "md-clip"), "--doctor"]
        if json_mode:
            command.append("--json")
        result = subprocess.run(
            command,
            env=self.env | environment,
            capture_output=True,
            check=False,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertNotIn(b"PRIVATE-", result.stdout)
        for call in self.log.read_text().splitlines():
            name = call.split()[0]
            if name in ("pbpaste", "pbcopy", "xclip", "wl-paste", "wl-copy"):
                self.assertTrue("--version" in call or "-version" in call, call)
            if name in ("clipboard-undo", "clipboard-undo-linux.py"):
                self.assertTrue(call.endswith(("['diagnose']", "['status']")), call)
            self.assertNotIn(name, ("clipboard-html", "clipboard-rtf"), call)
        if json_mode:
            return json.loads(result.stdout)
        return result.stdout.decode()

    @contextmanager
    def without_tool(self, name):
        tool = self.runtime / name
        hidden = self.base / name
        tool.rename(hidden)
        try:
            yield
        finally:
            hidden.rename(tool)

    def assert_diagnostic(self, document, code):
        self.assertIn(
            code, [issue["code"] for issue in document["diagnostics"]], document
        )


class BackendCases:
    def test_ready_backend_in_json_and_text(self):
        document = self.run_doctor()
        self.assertIs(document["native_preview"], False)
        self.assertEqual(document["backend"], self.backend)
        self.assertEqual(document["diagnostics_version"], 1)
        self.assertEqual(document["session"], {"status": "ready", "code": "ok"})
        self.assertEqual(
            document["capabilities"],
            {
                "plain_input": True,
                "html_conversion": True,
                "rtf_conversion": True,
                "clipboard_read": True,
                "clipboard_replace": True,
            },
        )
        self.assertFalse(document["diagnostics"])
        self.assertEqual(
            document["dependencies"]["pandoc"]["version"],
            'pandoc "quoted"\\versioncontrol',
        )
        self.assertIn("Fähigkeiten:", self.run_doctor(json_mode=False))

    def assert_session_problem(self, document, code, status):
        self.assertEqual(
            document["session"], {"status": status, "code": code}, document
        )
        self.assert_diagnostic(document, code)
        self.assertTrue(
            all(
                issue["message"] and issue["next_step"]
                for issue in document["diagnostics"]
            )
        )
        self.assertFalse(document["capabilities"]["clipboard_replace"])

    def test_missing_undo_helper(self):
        helper = (
            "clipboard-undo" if self.platform == "Darwin" else "clipboard-undo-linux.py"
        )
        with self.without_tool(helper):
            document = self.run_doctor()
        self.assert_session_problem(document, "undo-helper-missing", "unverified")

    def test_known_undo_diagnostics(self):
        problems = (
            ("python-unsupported", "unverified"),
            ("local-security-unsupported", "unverified"),
            ("runtime-unsafe", "unavailable"),
            ("x11-libraries-missing", "unverified"),
            ("x11-session-missing", "unavailable"),
            ("x11-connect-failed", "unavailable"),
            ("x11-xfixes-missing", "unsupported"),
            ("wayland-runtime-missing", "unavailable"),
            ("wayland-connect-failed", "unavailable"),
            ("wayland-data-control-missing", "unsupported"),
            ("wayland-seat-unsupported", "unsupported"),
            ("macos-session-missing", "unavailable"),
        )
        for code, status in problems:
            with self.subTest(code=code):
                document = self.run_doctor(MOCK_DIAG=code)
                self.assert_session_problem(document, code, status)

    def test_invalid_undo_diagnostic_is_generic(self):
        for value in ("unknown", "ok\nPRIVATE-CLIPBOARD-CONTENT"):
            with self.subTest(value=value):
                document = self.run_doctor(MOCK_DIAG=value)
                self.assertEqual(document["session"]["code"], "undo-helper-failed")
        document = self.run_doctor(MOCK_DIAG_FAIL="1")
        self.assertEqual(document["session"]["code"], "undo-helper-failed")

    def test_native_writer_without_external_command(self):
        with self.without_tool(self.external_writer):
            document = self.run_doctor()
        self.assertTrue(document["capabilities"]["clipboard_replace"])
        self.assertTrue(document["clipboard_tools"]["write"])
        self.assertEqual(
            document["capabilities"]["clipboard_read"], self.backend != "x11"
        )
        self.assertNotIn(
            "clipboard-write-tool-missing",
            [issue["code"] for issue in document["diagnostics"]],
        )


class X11DoctorTests(BackendCases, DoctorTestCase):
    backend = "x11"
    external_writer = "xclip"

    def test_broken_pandoc_features(self):
        problems = (
            ("MOCK_PANDOC_FAIL", "pandoc-unusable"),
            ("MOCK_NO_SANDBOX", "pandoc-no-sandbox"),
            ("MOCK_NO_FILTER", "table-filter-unavailable"),
            ("MOCK_NO_RTF", "pandoc-no-rtf"),
        )
        for flag, issue in problems:
            with self.subTest(flag=flag):
                self.assert_diagnostic(self.run_doctor(**{flag: "1"}), issue)

    def test_missing_tools_preserve_plain_input(self):
        tools = (
            ("pandoc", "pandoc-missing"),
            ("perl", "perl-missing"),
            ("python3", "python-missing"),
            ("xclip", "clipboard-read-tool-missing"),
        )
        for tool, issue in tools:
            with self.subTest(tool=tool), self.without_tool(tool):
                document = self.run_doctor()
                self.assert_diagnostic(document, issue)
                self.assertTrue(document["capabilities"]["plain_input"])


class WaylandDoctorTests(BackendCases, DoctorTestCase):
    backend = "wayland"
    wayland_display = "test-wayland"
    external_writer = "wl-copy"


@unittest.skipUnless(os.uname().sysname == "Darwin", "macOS erforderlich")
class MacOSDoctorTests(BackendCases, DoctorTestCase):
    backend = "macos"
    platform = "Darwin"
    external_writer = "pbcopy"

    def test_native_preview_requires_working_undo_status(self):
        preview = self.base / "helpers" / "md-clip-preview"
        preview.parent.mkdir()
        preview.write_text("#!/bin/sh\nexit 91\n")
        preview.chmod(0o755)
        self.assertIs(self.run_doctor()["native_preview"], True)
        self.assertIn("Fenstervorschau: verfügbar;", self.run_doctor(json_mode=False))
        document = self.run_doctor(MOCK_STATUS_FAIL="1")
        self.assertIs(document["native_preview"], False)
        self.assertIn(
            "Fenstervorschau: nicht verfügbar;",
            self.run_doctor(json_mode=False, MOCK_STATUS_FAIL="1"),
        )
        self.assert_diagnostic(document, "preview-status-unavailable")

    def test_missing_macos_tools_and_helpers(self):
        tools = (
            ("textutil", "textutil-missing"),
            ("clipboard-html", "html-helper-missing"),
            ("clipboard-rtf", "rtf-helper-missing"),
        )
        for tool, issue in tools:
            with self.subTest(tool=tool), self.without_tool(tool):
                document = self.run_doctor()
                self.assert_diagnostic(document, issue)
                if tool == "textutil":
                    self.assertFalse(document["capabilities"]["rtf_conversion"])


if __name__ == "__main__":
    unittest.main()
