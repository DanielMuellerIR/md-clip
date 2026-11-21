#!/usr/bin/env python3
"""CLI-Verhalten mit echten Konvertern und drei vollständig isolierten Backends."""

import fcntl
import json
import os
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from pathlib import Path

from lib.runtime import stage_runtime

NESTED = (
    b"<table><tr><th>Outer</th></tr><tr><td>before"
    b"<table><tr><th>Inner</th></tr><tr><td>VALUE</td></tr></table>"
    b"after</td></tr></table>"
)
TARGETS = ("gfm", "markdown", "commonmark")
INVISIBLE_HTML = [
    b"<p><strong>&lrm;</strong></p>",
    b"<p><em>&#x200B;</em></p>",
    b"<p><strong>&nbsp;</strong></p>",
    b"<blockquote><p><em>&rlm;</em></p></blockquote>",
    b"<pre><code>&#x2061;</code></pre>",
    b"<html><head><title>Title</title></head><body><b>&lrm;</b></body></html>",
]

CLIPBOARD_MOCK = r"""import os
import sys
import time
from pathlib import Path

name = Path(sys.argv[0]).name
args = sys.argv[1:]
base = Path(os.environ["MOCK_ROOT"])
with (base / "interpreters").open("a") as log:
    log.write(os.path.realpath(sys.executable) + "\n")
if name == "uname":
    print(os.environ["MOCK_PLATFORM"])
    sys.exit()
undo = name in ("clipboard-undo", "clipboard-undo-linux.py")
if undo and args == ["available"]:
    sys.exit()
if undo and args == ["diagnose"]:
    print("ok")
    sys.exit()
if undo and args == ["status"]:
    sys.exit(1 if os.environ.get("UNDO_FAIL_STATUS") else 0)
if "--version" in args or "-version" in args:
    print("mock 1.0")
    sys.exit()
with (base / "calls").open("a") as log:
    log.write(name + "\n")
if os.environ.get("NO_CLIP") == "1":
    sys.exit(90)
if undo:
    action = args[0]
    with (base / "undo-calls").open("a") as log:
        log.write(action + "\n")
    if action == "prepare":
        if os.environ.get("UNDO_FAIL_PREPARE"):
            sys.exit(1)
        print("mock-token")
        sys.exit()
    if action == "cancel":
        if os.environ.get("UNDO_PAUSE_CANCEL"):
            (base / "cancel-start").write_text(str(os.getpid()))
            time.sleep(1)
        sys.exit()
    if action == "replace":
        if os.environ.get("UNDO_FAIL_REPLACE"):
            sys.exit(1)
        (base / "written").write_bytes(sys.stdin.buffer.read())
        sys.exit()
    if action == "undo":
        sys.exit(0 if os.environ.get("UNDO_SUCCESS") else 1)
if name in ("pbcopy", "wl-copy") or "-in" in args:
    (base / "written").write_bytes(sys.stdin.buffer.read())
    sys.exit()
kind = "plain"
if name == "clipboard-html" or "text/html" in args:
    kind = "html"
if name == "clipboard-rtf" or "text/rtf" in args or "application/rtf" in args:
    kind = "rtf"
source = base / kind
if not source.exists():
    sys.exit(1)
sys.stdout.buffer.write(source.read_bytes())
"""

WRONG_PYTHON = """#!/bin/sh
[ "$1" = --version ] && { echo "Python 3.test"; exit 0; }
echo unwanted > "$MOCK_ROOT/unwanted-interpreter"
exit 92
"""

CAT_MOCK = r"""#!/bin/sh
if [ "${MOCK_TRACK_CAT:-}" = 1 ]; then
    printf '%s\n' "$$" > "$MOCK_ROOT/io-cat-pid"
fi
exec /bin/cat "$@"
"""

PREVIEW_MOCK = """import os
import sys
import time
from pathlib import Path

base = Path(os.environ["MOCK_ROOT"])
(base / "preview-data").write_bytes(Path(sys.argv[1]).read_bytes())
(base / "preview-notes").write_bytes(Path(sys.argv[2]).read_bytes())
(base / "preview-process").write_text(str(os.getpid()))
assert Path(sys.argv[3]).name == "clipboard-undo" and sys.argv[4] == "mock-token"
if os.environ.get("MOCK_PREVIEW_PAUSE"):
    time.sleep(30)
sys.exit(int(os.environ.get("MOCK_PREVIEW_STATUS", "0")))
"""


COUNT_CONVERSIONS_MOCK = r"""import os
import sys
from pathlib import Path

if "--wrap=none" in sys.argv:
    base = Path(os.environ["MOCK_ROOT"])
    with (base / "conversions").open("a") as log:
        log.write("1\n")
pandoc = os.environ["REAL_PANDOC"]
os.execv(pandoc, [pandoc, *sys.argv[1:]])
"""


def python_mock(source):
    return "#!" + os.path.realpath(sys.executable) + "\n" + source


class CliTestCase(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="md-clip-contract-")
        self.addCleanup(directory.cleanup)
        self.base = Path(directory.name)
        self.runtime = self.base / "bin"
        self.runtime.mkdir()
        stage_runtime(self.runtime)
        self.real_pandoc = shutil.which("pandoc")
        self.assertIsNotNone(self.real_pandoc)
        # Die CLI priorisiert das Pandoc neben der Laufzeitkopie.
        (self.runtime / "pandoc").symlink_to(self.real_pandoc)
        for name in (
            "uname",
            "pbpaste",
            "pbcopy",
            "wl-paste",
            "wl-copy",
            "xclip",
            "clipboard-html",
            "clipboard-rtf",
            "clipboard-undo",
            "clipboard-undo-linux.py",
        ):
            self.write_executable(self.runtime / name, python_mock(CLIPBOARD_MOCK))
        # Das Python im Produkt-PATH darf die Attrappen nicht ausführen.
        self.write_executable(self.runtime / "python3", WRONG_PYTHON)
        self.write_executable(self.runtime / "cat", CAT_MOCK)
        self.env = dict(
            os.environ,
            PATH=str(self.runtime) + os.pathsep + os.environ["PATH"],
            MOCK_ROOT=str(self.base),
            MOCK_PLATFORM="Linux",
            WAYLAND_DISPLAY="",
            NO_CLIP="1",
        )
        self.command = [str(self.runtime / "md-clip")]

    def tearDown(self):
        if self.env.get("NO_CLIP") == "1":
            self.assertFalse(
                (self.base / "calls").exists(), "Unerwarteter Clipboard-Aufruf"
            )
        interpreters = set((self.base / "interpreters").read_text().splitlines())
        self.assertEqual(interpreters, {os.path.realpath(sys.executable)})
        self.assertFalse((self.base / "unwanted-interpreter").exists())

    @staticmethod
    def write_executable(path, script):
        path.write_text(script)
        path.chmod(0o755)

    def run_cli(self, args=(), data=None, rc=0):
        result = subprocess.run(
            [*self.command, *args],
            input=data,
            capture_output=True,
            check=False,
            env=self.env,
            timeout=20,
        )
        self.assertEqual(result.returncode, rc, (args, result.stderr))
        return result

    def undo_calls(self):
        path = self.base / "undo-calls"
        calls = path.read_text().splitlines() if path.exists() else []
        path.unlink(missing_ok=True)
        return calls

    def read_pandoc_json(self, target, markdown):
        if target == "commonmark":
            target += "+pipe_tables"
        return json.loads(
            subprocess.check_output(
                [self.real_pandoc, "-f", target, "-t", "json"],
                input=markdown,
            )
        )


class InputTests(CliTestCase):
    def test_command_options_are_validated_before_actions(self):
        for action in ("--version", "--help", "--check-updates", "--doctor", "--undo"):
            for option in (
                "--unknown",
                "--plain",
                "--replace",
                "--preview",
                "--preview-window",
            ):
                for args in ([action, option], [option, action]):
                    invalid = self.run_cli(args, rc=2)
                    self.assertTrue(not invalid.stdout and invalid.stderr)
        for option in (
            ["--from", "html"],
            ["--to", "gfm"],
            ["--images", "keep"],
            ["--tables", "reject"],
        ):
            self.run_cli(["--doctor", *option], rc=2)
        self.assertTrue(self.run_cli(["--version"]).stdout.startswith(b"md-clip "))
        self.assertIn(b"--help", self.run_cli(["--help"]).stdout)
        self.assertIn(
            b"App-Installation", self.run_cli(["--check-updates"], rc=2).stderr
        )

    def test_report_creation_failure_prevents_output(self):
        # Das Verzeichnis "result" blockiert nur die Berichtsdatei.
        real_mktemp = shutil.which("mktemp")
        self.write_executable(
            self.runtime / "mktemp",
            f"""#!/bin/bash
work=$("{real_mktemp}" "$@") || exit
mkdir "$work/result"
printf '%s\\n' "$work"
""",
        )
        invalid = self.run_cli(["--stdin", "--from", "plain"], b"plain\n", rc=3)
        self.assertTrue(
            not invalid.stdout and b"Konvertierungsbericht" in invalid.stderr
        )

    def test_plain_stdin_preserves_bytes(self):
        for raw in (
            b"abc",
            b"abc\n\n",
            b"\x00\xff\r\n",
            b"\n\n",
            rb"{\rtf1 literal}" + b"\x00\xff\n",
        ):
            self.assertEqual(self.run_cli(["--stdin", "--plain"], raw).stdout, raw)
            self.assertEqual(
                self.run_cli(["--stdin", "--plain", "--strict"], raw).stdout, raw
            )

    def test_invalid_input_and_conversion_options(self):
        for args in (
            ["--stdin"],
            ["--stdin", "--input", "x"],
            ["--json"],
            ["--preview"],
            ["--plain", "--from", "html"],
            ["--input", "missing.html"],
        ):
            self.run_cli(args, b"x", 2)
        self.run_cli(["--doctor", "--strict"], rc=2)
        for args in (
            ["--preview-window"],
            ["--undo", "--preview-window"],
            ["--doctor", "--preview-window"],
            ["--replace", "--preview-window", "--preview"],
        ):
            self.run_cli(args, rc=2)
        for args in (
            ["--images"],
            ["--images", "invalid"],
            ["--doctor", "--images", "alt"],
            ["--tables"],
            ["--tables", "invalid"],
            ["--doctor", "--tables", "text"],
        ):
            self.run_cli(args, rc=2)

    def test_invalid_explicit_rtf_is_rejected(self):
        for raw in (
            b"plain tagged as RTF",
            b"<p>HTML tagged as RTF</p>",
            rb"{\rtf10\ansi wrong version}",
            rb"{\rtf1broken}",
        ):
            for target in TARGETS:
                invalid = self.run_cli(
                    ["--stdin", "--from", "rtf", "--to", target], raw, 3
                )
                self.assertTrue(not invalid.stdout and b"RTF-Kopf" in invalid.stderr)
        wrong_rtf = self.base / "RTF source with space.rtf"
        wrong_rtf.write_bytes(b"plain tagged as RTF\n\n")
        self.assertIn(
            b"RTF-Kopf", self.run_cli(["--input", str(wrong_rtf)], rc=3).stderr
        )
        self.assertEqual(
            self.run_cli(["--input", str(wrong_rtf), "--plain"]).stdout,
            wrong_rtf.read_bytes(),
        )

    def test_plain_file_and_empty_stdin(self):
        source = self.base / "file with space.txt"
        source.write_bytes(b"file\n\n")
        self.assertEqual(
            self.run_cli(["--input", str(source)]).stdout, source.read_bytes()
        )
        self.run_cli(["--stdin", "--plain"], b"", 1)

    def test_unwritable_stdout_is_an_output_error(self):
        (self.base / "file with space.txt").write_bytes(b"file\n\n")
        # Ein nur lesbarer stdout muss als Ausgabefehler (3) gemeldet werden.
        with (self.base / "file with space.txt").open("rb") as readonly:
            failed = subprocess.run(
                [*self.command, "--stdin", "--plain"],
                input=b"x",
                check=False,
                stdout=readonly,
                stderr=subprocess.PIPE,
                env=self.env,
                timeout=20,
            )
        self.assertEqual(failed.returncode, 3, (failed.returncode, failed.stderr))
        self.assertIn(b"stdout", failed.stderr)

    def test_invisible_html_is_empty(self):
        for target in TARGETS:
            for html in INVISIBLE_HTML:
                self.run_cli(["--stdin", "--from", "html", "--to", target], html, 3)
            for html in (
                b"<p><strong>visible</strong></p>",
                b"<p><code>**</code></p>",
                b'<img src="image.png">',
                b"<hr>",
            ):
                self.assertTrue(
                    self.run_cli(
                        ["--stdin", "--from", "html", "--to", target], html
                    ).stdout.strip()
                )

    def test_unsupported_table_structure_is_rejected(self):
        for target in TARGETS:
            self.run_cli(["--stdin", "--from", "html", "--to", target], NESTED, 3)
            self.run_cli(
                ["--stdin", "--from", "html", "--to", target],
                NESTED.replace(b"<table>", b"<TaBlE\n>"),
                3,
            )
            p = self.run_cli(
                ["--stdin", "--from", "html", "--to", target], b"<p>[TABLE]</p>"
            )
            self.assertIn(b"TABLE", p.stdout)
            p = self.run_cli(
                ["--stdin", "--from", "html", "--to", target],
                b'<p title="<table>">literal</p><!-- <table><table> -->',
            )
            self.assertIn(b"literal", p.stdout)
            self.run_cli(
                ["--stdin", "--from", "html", "--to", target],
                b'<table><tr><th>A</th><th>B</th></tr><tr><td colspan="2">VALUE</td></tr></table>',
                3,
            )

    def test_strict_mode_only_rejects_flattened_cells(self):
        complex_cells = b"<table><tr><th>A</th><th>B</th></tr><tr><td>one<br>two</td><td><p>three</p><p>four</p></td></tr></table>"
        simple_table = b"<table><tr><th>A</th></tr><tr><td>value</td></tr></table>"
        for target in TARGETS:
            args = ["--stdin", "--from", "html", "--to", target]
            self.assertTrue(self.run_cli(args + ["--strict"], simple_table).stdout)
            p = self.run_cli(args, complex_cells)
            if target == "markdown":
                self.assertNotIn(b"Vereinfachung", p.stderr)
                self.assertEqual(
                    self.run_cli(args + ["--strict"], complex_cells).stdout, p.stdout
                )
            else:
                self.assertIn(b"2 Tabellenzellen", p.stderr)
                self.assertFalse(
                    self.run_cli(args + ["--strict"], complex_cells, 3).stdout
                )

    def test_rtf_table_remains_a_table_in_text_mode(self):
        rtf_table = rb"{\rtf1\ansi\trowd\cellx1000\cellx2000\intbl RTFLEFT\cell RTFRIGHT\cell\row}"
        for target in TARGETS:
            p = self.run_cli(
                ["--stdin", "--from", "rtf", "--tables", "text", "--to", target],
                rtf_table,
            )
            parsed = self.read_pandoc_json(target, p.stdout)
            self.assertEqual(parsed["blocks"][0]["t"], "Table", p.stdout)
            self.assertTrue(b"RTFLEFT" in p.stdout and b"RTFRIGHT" in p.stdout)

    def test_invalid_conversion_report_prevents_output(self):
        filter_file = self.runtime / "pandoc-filter.lua"
        for record in (
            "table-cells-flattened\tbogus\n",
            "table-cells-flattened\t0\n",
            "table-cells-flattened\t\t1\n",
            "table-cells-flattened\t1\t\n",
            "table-cells-flattened\t1",
            "unknown\t1\n",
        ):
            filter_file.write_bytes(
                (
                    "function Pandoc(doc)\n"
                    'local f=assert(io.open(os.getenv("MD_CLIP_RESULT_FILE"),"a"))\n'
                    "f:write(" + json.dumps(record) + "); f:close(); return doc\nend\n"
                ).encode()
            )
            invalid = self.run_cli(["--stdin", "--from", "html"], b"<p>valid</p>", 3)
            self.assertTrue(
                not invalid.stdout and b"Konvertierungsbericht" in invalid.stderr
            )

    def test_flattened_cells_keep_all_text_in_one_cell(self):
        for inner, expected in (
            (b"<blockquote><p>ONE</p><p>TWO</p></blockquote>", "ONE TWO"),
            (b"<ul><li>ONE</li><li>TWO</li></ul>", "ONE TWO"),
            (b"<dl><dt>TERM</dt><dd>DEF</dd></dl>", "TERM DEF"),
            (b"<pre><code>ONE\nTWO</code></pre>", "ONE TWO"),
        ):
            for target in ("gfm", "commonmark"):
                html = (
                    b"<table><tr><th>HEAD</th></tr><tr><td>"
                    + inner
                    + b"</td></tr></table>"
                )
                output = self.run_cli(
                    ["--stdin", "--from", "html", "--to", target], html
                ).stdout
                parsed = self.read_pandoc_json(target, output)
                table = parsed["blocks"][0]
                self.assertEqual(table["t"], "Table", output)
                rows = table["c"][4][0][3]
                self.assertTrue(len(rows) == 1 and len(rows[0][1]) == 1, output)
                cell = rows[0][1][0][4]
                # Wieder als Plain schreiben: Code und Fließtext haben dieselben Worte.
                doc = dict(parsed, blocks=cell)
                text = (
                    subprocess.check_output(
                        [self.real_pandoc, "-f", "json", "-t", "plain"],
                        input=json.dumps(doc).encode(),
                    )
                    .decode()
                    .strip()
                )
                self.assertEqual(text, expected, (output, text))

    def test_internal_environment_does_not_change_options(self):
        self.env["MD_CLIP_STRICT"] = "1"
        self.env["MD_CLIP_TABLES"] = "text"
        self.env["MD_CLIP_IMAGES"] = "omit"
        self.assertIn(
            b"![",
            self.run_cli(
                ["--stdin", "--from", "html"], b'<img src="x" alt="Y">'
            ).stdout,
        )
        self.run_cli(["--stdin", "--from", "html"], NESTED, 3)
        doctor = json.loads(self.run_cli(["--doctor", "--json"]).stdout)
        self.assertEqual(doctor["table_modes"], ["reject", "text"])
        self.assertTrue(
            doctor["stdin"]
            and doctor["sandbox"]
            and doctor["undo"]
            and doctor["strict"]
        )
        self.assertEqual(doctor["image_modes"], ["keep", "alt", "omit"])
        self.assertTrue(
            doctor["table_filter"],
            "Interne Umgebungswerte dürfen Doctor nicht verändern",
        )

    def test_raw_text_and_encoded_colspan(self):
        for target in TARGETS:
            for tag in ("textarea", "title"):
                source = (
                    "<p>BEFORE</p><"
                    + tag
                    + '><td rowspan="0">literal</'
                    + tag
                    + "><p>AFTER</p>"
                ).encode()
                result = self.run_cli(
                    [
                        "--stdin",
                        "--from",
                        "html",
                        "--to",
                        target,
                        "--tables",
                        "text",
                        "--strict",
                        "--quiet",
                    ],
                    source,
                )
                self.assertTrue(
                    b"BEFORE" in result.stdout
                    and b"AFTER" in result.stdout
                    and not result.stderr
                )
            for value in ("&#50", "&#x32"):
                source = (
                    '<table><tr><td colspan="' + value + '">CELL</td></tr></table>'
                ).encode()
                result = self.run_cli(
                    ["--stdin", "--from", "html", "--to", target, "--tables", "text"],
                    source,
                )
                self.assertTrue(
                    b"CELL" in result.stdout
                    and b"2 Spalten" in result.stdout
                    and b"beschrifteten Text" in result.stderr
                )
                result = self.run_cli(
                    [
                        "--stdin",
                        "--from",
                        "html",
                        "--to",
                        target,
                        "--tables",
                        "text",
                        "--strict",
                    ],
                    source,
                    3,
                )
                self.assertTrue(
                    not result.stdout and b"Strukturvereinfachung" in result.stderr
                )

    def test_plain_mode_does_not_invoke_broken_pandoc(self):
        # Kein pandoc-Aufruf im Plain-Weg, auch bei vorhandenem defektem Binary.
        (self.runtime / "pandoc").unlink()
        (self.runtime / "pandoc").write_text(
            '#!/bin/sh\necho touched > "$MOCK_ROOT/pandoc-called"\nexit 88\n'
        )
        (self.runtime / "pandoc").chmod(0o755)
        self.assertEqual(
            self.run_cli(["--stdin", "--plain"], b"bytes\n").stdout, b"bytes\n"
        )
        self.assertEqual(
            self.run_cli(["--stdin", "--plain", "--strict"], b"bytes\n").stdout,
            b"bytes\n",
        )
        for mode in ("keep", "alt", "omit"):
            self.assertEqual(
                self.run_cli(
                    ["--stdin", "--plain", "--images", mode], b"![image](x)\x00\n"
                ).stdout,
                b"![image](x)\x00\n",
            )
        self.assertEqual(
            self.run_cli(
                ["--stdin", "--plain", "--tables", "text"], b"|x|\x00\n"
            ).stdout,
            b"|x|\x00\n",
        )
        self.assertFalse((self.base / "pandoc-called").exists())
        broken = json.loads(self.run_cli(["--doctor", "--json"]).stdout)
        self.assertTrue(not broken["sandbox"] and not broken["table_filter"])


class ClipboardCases:
    def setUp(self):
        super().setUp()
        self.env.update(
            MOCK_PLATFORM=self.platform, WAYLAND_DISPLAY=self.wayland_display
        )
        del self.env["NO_CLIP"]

    def test_word_detection_preserves_original_html(self):
        (self.base / "rtf").write_bytes(b"{\\rtf1\\ansi RTF selected}")
        for rich, expected in (
            (b"<p>HTML safe</p>\x00", b"HTML safe\n"),
            (b"<p>HTML safe</p>\x00\x00", b"HTML safe\n"),
            (
                b'<html xmlns:o="urn:schemas-microsoft-com:office:office">\x00<p>HTML</p></html>',
                b"RTF selected\n",
            ),
            (b"<p>HTML</p><!-- " + b"mso-x " * 9 + b"-->", b"HTML\n"),
            (b"<p>HTML</p>\x00<!-- " + b"ms\x00o-x " * 10 + b"-->", b"RTF selected\n"),
            (
                b'<meta name=Generator content="Microsoft Word"><p>HTML</p>',
                b"RTF selected\n",
            ),
        ):
            (self.base / "html").write_bytes(rich)
            result = self.run_cli(["--quiet"])
            self.assertTrue(
                result.stdout == expected and not result.stderr,
                (
                    result.stdout,
                    result.stderr,
                ),
            )
            self.assertEqual((self.base / "html").read_bytes(), rich)

    def test_undo_dispatch_and_option_validation(self):
        for args in (
            ["--undo", "--replace"],
            ["--undo", "--plain"],
            ["--undo", "--stdin"],
            ["--undo", "--from", "auto"],
            ["--undo", "--doctor"],
            ["--undo", "--preview"],
            ["--undo", "--strict"],
            ["--undo", "--images", "keep"],
            ["--undo", "--tables", "reject"],
        ):
            self.run_cli(args, rc=2)
        self.undo_calls()
        self.run_cli(["--undo"], rc=1)
        self.assertEqual(self.undo_calls(), ["undo"])
        (self.base / "calls").unlink(missing_ok=True)
        self.env["UNDO_SUCCESS"] = "1"
        self.assertFalse(self.run_cli(["--undo"]).stdout)
        self.assertEqual(self.undo_calls(), ["undo"])
        self.assertEqual(
            (self.base / "calls").read_text().splitlines(),
            [
                "clipboard-undo"
                if self.platform == "Darwin"
                else "clipboard-undo-linux.py"
            ],
        )
        self.env.pop("UNDO_SUCCESS")

    def test_binary_conversion_report_prevents_auto_fallback_and_replace(self):
        (self.base / "html").write_bytes(b"<p>Rich format</p>")
        (self.base / "plain").write_bytes(b"plain fallback")
        (self.base / "written").write_bytes(b"protected")
        report = self.runtime / "pandoc-filter.lua"
        for record in (b"images-omitted\t1\x00\n", b"images-omitted\t1\n\x00", b"\x00"):
            values = ", ".join(str(byte) for byte in record)
            report.write_text(
                "function Pandoc(doc)\n"
                '  local f = assert(io.open(os.getenv("MD_CLIP_RESULT_FILE"), "ab"))\n'
                f"  f:write(string.char({values}))\n"
                "  f:close()\n"
                "  return doc\n"
                "end\n"
            )
            result = self.run_cli(["--replace"], rc=3)
            self.assertFalse(result.stdout)
            self.assertIn(b"Konvertierungsbericht", result.stderr)
            self.assertEqual((self.base / "written").read_bytes(), b"protected")
            self.assertEqual(self.undo_calls(), ["prepare", "cancel"])

    def test_failed_prepare_or_replace_preserves_clipboard(self):
        for flag in ("UNDO_FAIL_PREPARE", "UNDO_FAIL_REPLACE"):
            (self.base / "written").write_bytes(b"protected")
            self.env[flag] = "1"
            self.run_cli(["--stdin", "--plain", "--replace"], b"new", 1)
            self.assertEqual((self.base / "written").read_bytes(), b"protected")
            self.assertEqual(
                self.undo_calls(),
                ["prepare"]
                if flag == "UNDO_FAIL_PREPARE"
                else ["prepare", "replace", "cancel"],
            )
            self.env.pop(flag)

    def test_invalid_rtf_falls_back_to_html_or_plain(self):
        (self.base / "html").write_bytes(
            b'<html xmlns:o="urn:schemas-microsoft-com:office:office"><p>HTML rescue</p></html>'
        )
        (self.base / "rtf").write_bytes(b"plain tagged as RTF")
        (self.base / "plain").write_bytes(b"plain fallback\n\n")
        for strict in (False, True):
            self.undo_calls()
            p = self.run_cli(["--replace", *(["--strict"] if strict else [])])
            self.assertTrue(
                (self.base / "written").read_bytes() == b"HTML rescue"
                and b"RTF-Kopf" in p.stderr
            )
            self.assertEqual(self.undo_calls(), ["prepare", "replace"])
        (self.base / "html").unlink()
        self.undo_calls()
        p = self.run_cli(["--replace"])
        self.assertTrue(
            (self.base / "written").read_bytes() == b"plain fallback\n\n"
            and b"RTF-Kopf" in p.stderr
        )
        self.assertEqual(self.undo_calls(), ["prepare", "replace"])
        (self.base / "written").write_bytes(b"protected")
        self.undo_calls()
        self.run_cli(["--replace", "--strict"], rc=3)
        self.assertTrue(
            (self.base / "written").read_bytes() == b"protected"
            and self.undo_calls() == ["prepare", "cancel"]
        )
        self.run_cli(["--replace", "--from", "rtf"], rc=3)
        self.assertTrue(
            (self.base / "written").read_bytes() == b"protected"
            and self.undo_calls() == ["prepare", "cancel"]
        )

    def test_nested_tables_fall_back_to_rtf_or_plain(self):
        (self.base / "plain").write_bytes(b"plain\n\n")
        for target in TARGETS:
            (self.base / "html").write_bytes(NESTED)
            (self.base / "rtf").write_bytes(b"{\\rtf1\\ansi RTF rescue}")
            p = self.run_cli(["--replace", "--to", target])
            self.assertEqual((self.base / "written").read_bytes(), b"RTF rescue")
            self.assertEqual(self.undo_calls(), ["prepare", "replace"])
            self.assertTrue(
                b"verschachtelte Tabelle" in p.stderr and b"RTF verwendet" in p.stderr
            )
            p = self.run_cli(["--replace", "--strict", "--to", target])
            self.assertEqual((self.base / "written").read_bytes(), b"RTF rescue")
            self.assertEqual(self.undo_calls(), ["prepare", "replace"])
            (self.base / "rtf").unlink()
            p = self.run_cli(["--replace", "--to", target])
            self.assertEqual((self.base / "written").read_bytes(), b"plain\n\n")
            self.assertEqual(self.undo_calls(), ["prepare", "replace"])
            self.assertTrue(b"Klartext" in p.stderr and not p.stdout)
            (self.base / "written").write_bytes(b"protected")
            p = self.run_cli(["--replace", "--strict", "--to", target], rc=3)
            self.assertTrue(b"Strenger Modus" in p.stderr and not p.stdout)
            self.assertEqual((self.base / "written").read_bytes(), b"protected")
            self.assertEqual(self.undo_calls(), ["prepare", "cancel"])
            self.run_cli(["--replace", "--from", "html", "--to", target], rc=3)
            self.assertEqual((self.base / "written").read_bytes(), b"protected")
            self.assertEqual(self.undo_calls(), ["prepare", "cancel"])

    def test_invisible_rich_input_falls_back_to_visible_content(self):
        (self.base / "plain").write_bytes(b"plain\n\n")
        for html in INVISIBLE_HTML:
            (self.base / "html").write_bytes(html)
            self.assertEqual(self.run_cli().stdout, b"plain\n\n")
            self.run_cli(["--replace"])
            self.assertEqual((self.base / "written").read_bytes(), b"plain\n\n")
            (self.base / "written").write_bytes(b"protected")
            self.run_cli(["--replace", "--from", "html"], rc=3)
            self.assertEqual((self.base / "written").read_bytes(), b"protected")
        (self.base / "html").write_bytes(
            b'<html xmlns:o="urn:schemas-microsoft-com:office:office"><p>HTML rescue</p></html>'
        )
        (self.base / "rtf").write_bytes(b"{\\rtf1\\ansi }")
        self.assertIn(b"HTML rescue", self.run_cli().stdout)

    def test_strict_mode_preserves_clipboard_on_table_cell_loss(self):
        (self.base / "plain").write_bytes(b"plain\n\n")
        (self.base / "html").write_bytes(
            b"<table><tr><th>A</th></tr><tr><td>one<br>two</td></tr></table>"
        )
        self.assertIn(b"Struktur vereinfacht", self.run_cli().stderr)
        self.assertIn(b"1 Tabellenzelle", self.run_cli().stderr)
        self.assertFalse(self.run_cli(["--quiet", "--verbose"]).stderr)
        for flags in (["--strict"], ["--strict", "--quiet"], ["--strict", "--preview"]):
            (self.base / "written").write_bytes(b"protected")
            self.undo_calls()
            p = self.run_cli(["--replace", *flags], rc=3)
            self.assertTrue(b"Strenger Modus" in p.stderr and not p.stdout)
            self.assertEqual((self.base / "written").read_bytes(), b"protected")
            self.assertEqual(self.undo_calls(), ["prepare", "cancel"])
        (self.base / "html").unlink()
        (self.base / "rtf").unlink(missing_ok=True)
        self.undo_calls()
        p = self.run_cli(["--strict", "--replace"])
        self.assertEqual((self.base / "written").read_bytes(), b"plain\n\n")
        self.assertTrue(
            b"R\xc3\xbcckfall" not in p.stderr and b"Vereinfachung" not in p.stderr
        )
        self.assertEqual(self.undo_calls(), ["prepare", "replace"])
        (self.base / "html").write_bytes(NESTED)
        self.undo_calls()
        self.run_cli(["--strict", "--plain", "--replace"])
        self.assertEqual((self.base / "written").read_bytes(), b"plain\n\n")
        self.assertEqual(self.undo_calls(), ["prepare", "replace"])

    def test_image_loss_is_reported_and_strict_mode_cancels(self):
        image_html = (
            b'<p>Text <img src="https://example.invalid/a.png" alt="Diagramm"></p>'
        )
        (self.base / "html").write_bytes(image_html)
        for target in TARGETS:
            for mode in ("alt", "omit"):
                self.undo_calls()
                p = self.run_cli(["--replace", "--images", mode, "--to", target])
                written = (self.base / "written").read_bytes()
                self.assertTrue(b"Text" in written and b"![" not in written)
                self.assertEqual(b"Diagramm" in written, mode == "alt")
                self.assertIn(b"1 Bild", p.stderr)
                self.assertEqual(self.undo_calls(), ["prepare", "replace"])
                (self.base / "written").write_bytes(b"protected")
                p = self.run_cli(
                    ["--replace", "--images", mode, "--strict", "--to", target], rc=3
                )
                self.assertTrue(b"Bildvereinfachung" in p.stderr and not p.stdout)
                self.assertEqual((self.base / "written").read_bytes(), b"protected")
                self.assertEqual(self.undo_calls(), ["prepare", "cancel"])

    def test_text_tables_and_empty_image_output(self):
        (self.base / "html").write_bytes(NESTED)
        for target in TARGETS:
            self.undo_calls()
            (self.base / "written").unlink(missing_ok=True)
            p = self.run_cli(
                ["--from", "html", "--replace", "--tables", "text", "--to", target]
            )
            self.assertIn(b"2 Tabellen", p.stderr)
            self.assertIn(b"VALUE", (self.base / "written").read_bytes())
            self.assertEqual(self.undo_calls(), ["prepare", "replace"])
            (self.base / "written").unlink()
            p = self.run_cli(
                [
                    "--from",
                    "html",
                    "--replace",
                    "--tables",
                    "text",
                    "--strict",
                    "--to",
                    target,
                ],
                rc=3,
            )
            self.assertTrue(not p.stdout and not (self.base / "written").exists())
            self.assertEqual(self.undo_calls(), ["prepare", "cancel"])
            self.assertIn(b"Strenger Modus", p.stderr)
        for mode in ("alt", "omit"):
            (self.base / "html").write_bytes(b'<img src="x">')
            (self.base / "written").write_bytes(b"protected")
            p = self.run_cli(["--from", "html", "--replace", "--images", mode], rc=3)
            self.assertTrue(
                not p.stdout and (self.base / "written").read_bytes() == b"protected"
            )
            self.assertEqual(self.undo_calls(), ["prepare", "cancel"])

    def test_non_terminal_preview_does_not_replace(self):
        (self.base / "html").write_bytes(NESTED)
        (self.base / "plain").write_bytes(b"plain\n\n")
        (self.base / "written").write_bytes(b"protected")
        self.run_cli(["--preview", "--replace"], rc=2)
        self.assertEqual((self.base / "written").read_bytes(), b"protected")
        self.undo_calls()

    def test_parent_signal_cancels_blocked_io(self):
        self.env["MOCK_TRACK_CAT"] = "1"
        for io_mode in ("stdin", "stdout"):
            for interruption, expected_code in (
                (signal.SIGINT, 130),
                (signal.SIGTERM, 143),
            ):
                self.undo_calls()
                (self.base / "io-cat-pid").unlink(missing_ok=True)
                if io_mode == "stdin":
                    command = [*self.command, "--stdin", "--plain", "--replace"]
                else:
                    source = self.base / "large-plain.txt"
                    source.write_bytes(b"X" * (4 * 1024 * 1024))
                    command = [*self.command, "--input", str(source), "--plain"]
                proc = subprocess.Popen(
                    command,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=self.env,
                    start_new_session=True,
                )
                group = proc.pid
                try:
                    deadline = time.monotonic() + 8
                    if io_mode == "stdout":
                        self.assertTrue(
                            select.select([proc.stdout], [], [], 8)[0],
                            "stdout-Kopie begann nicht",
                        )
                        self.assertEqual(proc.stdout.read(1), b"X")
                    else:
                        while (
                            not (self.base / "io-cat-pid").exists()
                            and time.monotonic() < deadline
                        ):
                            time.sleep(0.01)
                    self.assertTrue(
                        (self.base / "io-cat-pid").exists(),
                        "I/O-Kindprozess begann nicht",
                    )
                    child = int((self.base / "io-cat-pid").read_text())
                    proc.send_signal(interruption)
                    deadline = time.monotonic() + 5
                    while proc.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertEqual(
                        proc.returncode,
                        expected_code,
                        "Elternsignal benötigte EOF/freien stdout: " + io_mode,
                    )
                    # Erst nach der Exit-Prüfung stdin schließen/stdout leeren.
                    out, _ = proc.communicate(timeout=2)
                    if io_mode == "stdin":
                        self.assertTrue(
                            not out and self.undo_calls() == ["prepare", "cancel"]
                        )
                    else:
                        self.assertTrue(
                            len(out) < 4 * 1024 * 1024 and not self.undo_calls()
                        )
                    try:
                        os.kill(child, 0)
                    except ProcessLookupError:
                        pass
                    else:
                        raise AssertionError("I/O-Kindprozess blieb aktiv")
                finally:
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.communicate(timeout=3)

    def test_terminal_stdin_preserves_bytes(self):
        master, slave = pty.openpty()
        attributes = termios.tcgetattr(slave)
        attributes[3] &= ~(termios.ECHO | termios.ECHONL)
        termios.tcsetattr(slave, termios.TCSANOW, attributes)
        proc = subprocess.Popen(
            [*self.command, "--stdin", "--plain"],
            stdin=slave,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            start_new_session=True,
        )
        os.close(slave)
        try:
            terminal_bytes = "Terminal ä😀\n".encode()
            os.write(master, terminal_bytes + b"\x04")
            out, error = proc.communicate(timeout=10)
            self.assertTrue(
                proc.returncode == 0 and out == terminal_bytes,
                (
                    proc.returncode,
                    out,
                    error,
                ),
            )
        finally:
            os.close(master)
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=3)

    def test_first_signal_controls_exit_during_cleanup(self):
        signal_work = self.base / "signal-work"
        signal_work.mkdir(exist_ok=True)
        self.env.update(
            TMPDIR=str(signal_work), UNDO_PAUSE_CANCEL="1", MOCK_TRACK_CAT="1"
        )
        for first, second, expected in (
            (signal.SIGINT, signal.SIGTERM, 130),
            (signal.SIGTERM, signal.SIGINT, 143),
        ):
            self.undo_calls()
            (self.base / "cancel-start").unlink(missing_ok=True)
            (self.base / "io-cat-pid").unlink(missing_ok=True)
            (self.base / "written").write_bytes(b"protected")
            proc = subprocess.Popen(
                [*self.command, "--stdin", "--plain", "--replace", "--quiet"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self.env,
                start_new_session=True,
            )
            try:
                proc.stdin.write(b"synthetic incomplete input")
                proc.stdin.flush()
                end = time.monotonic() + 8
                while time.monotonic() < end:
                    sources = list(signal_work.glob("md-clip.*/plain"))
                    if (
                        sources
                        and sources[0].read_bytes() == b"synthetic incomplete input"
                    ):
                        break
                    time.sleep(0.01)
                else:
                    raise AssertionError("Private Teilquelle nicht erreicht")
                proc.send_signal(first)
                end = time.monotonic() + 5
                while (
                    not (self.base / "cancel-start").exists() and time.monotonic() < end
                ):
                    time.sleep(0.01)
                self.assertTrue(
                    (self.base / "cancel-start").exists(), "Stornierung begann nicht"
                )
                proc.send_signal(second)
                self.assertEqual(
                    proc.wait(timeout=5),
                    expected,
                    "Weiteres Signal änderte ersten Exit",
                )
                out, error = proc.communicate(timeout=2)
                self.assertTrue(
                    not out and not list(signal_work.iterdir()),
                    (
                        out,
                        error,
                        list(signal_work.iterdir()),
                    ),
                )
                self.assertTrue(
                    (self.base / "written").read_bytes() == b"protected"
                    and self.undo_calls()
                    == [
                        "prepare",
                        "cancel",
                    ]
                )
                for marker in ("io-cat-pid", "cancel-start"):
                    child = int((self.base / marker).read_text())
                    try:
                        os.kill(child, 0)
                    except ProcessLookupError:
                        pass
                    else:
                        raise AssertionError("Cleanup-Kindprozess blieb aktiv")
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate(timeout=3)


class LinuxClipboardCases(ClipboardCases):
    def test_native_preview_is_unavailable(self):
        (self.base / "preview-data").unlink(missing_ok=True)
        self.run_cli(["--replace", "--preview-window"], rc=2)
        self.assertTrue(
            not (self.base / "preview-data").exists() and not self.undo_calls()
        )


class X11ClipboardTests(LinuxClipboardCases, CliTestCase):
    platform = "Linux"
    wayland_display = ""


class WaylandClipboardTests(LinuxClipboardCases, CliTestCase):
    platform = "Linux"
    wayland_display = "mock-wayland"


@unittest.skipUnless(os.uname().sysname == "Darwin", "macOS erforderlich")
class MacOSClipboardTests(ClipboardCases, CliTestCase):
    platform = "Darwin"
    wayland_display = ""

    def setUp(self):
        super().setUp()
        preview = self.base / "helpers" / "md-clip-preview"
        preview.parent.mkdir()
        self.write_executable(preview, python_mock(PREVIEW_MOCK))

    def test_native_preview_requires_undo_status(self):
        self.env["UNDO_FAIL_STATUS"] = "1"
        (self.base / "preview-data").unlink(missing_ok=True)
        p = self.run_cli(["--replace", "--preview-window"], rc=2)
        self.assertTrue(
            b"Undo-Status" in p.stderr
            and not self.undo_calls()
            and not (self.base / "preview-data").exists()
        )
        self.env.pop("UNDO_FAIL_STATUS")

    def test_native_preview_reuses_the_conversion_and_honors_decision(self):
        (self.base / "html").write_bytes(b'<p>Text <img src="x" alt="BILD"></p>')
        (self.runtime / "pandoc").unlink()
        self.env["REAL_PANDOC"] = self.real_pandoc
        self.write_executable(
            self.runtime / "pandoc", python_mock(COUNT_CONVERSIONS_MOCK)
        )
        for decision, code in ((0, 0), (4, 4), (64, 3)):
            self.undo_calls()
            (self.base / "conversions").unlink(missing_ok=True)
            (self.base / "written").write_bytes(b"protected")
            self.env["MOCK_PREVIEW_STATUS"] = str(decision)
            p = self.run_cli(
                [
                    "--from",
                    "html",
                    "--replace",
                    "--preview-window",
                    "--images",
                    "alt",
                    "--quiet",
                ],
                rc=code,
            )
            self.assertEqual(
                (self.base / "conversions").read_text().splitlines(), ["1"]
            )
            self.assertTrue(
                b"1 Bild" in (self.base / "preview-notes").read_bytes()
                and b"Quelle: HTML" in (self.base / "preview-notes").read_bytes()
            )
            self.assertEqual(
                self.undo_calls(),
                ["prepare", "replace"] if decision == 0 else ["prepare", "cancel"],
            )
            self.assertEqual(
                (self.base / "written").read_bytes(),
                (self.base / "preview-data").read_bytes()
                if decision == 0
                else b"protected",
            )
            self.assertFalse(p.stdout)
        self.env["MOCK_PREVIEW_STATUS"] = "5"
        self.env["UNDO_SUCCESS"] = "1"
        self.undo_calls()
        self.run_cli(["--from", "html", "--replace", "--preview-window"])
        self.assertEqual(self.undo_calls(), ["prepare", "cancel", "undo"])

    def test_native_preview_surfaces_fallback_and_strict_prevents_opening(self):
        (self.base / "html").write_bytes(NESTED)
        (self.base / "rtf").write_bytes(b"{\\rtf1\\ansi RTF rescue}")
        self.undo_calls()
        self.run_cli(["--replace", "--preview-window"])
        self.assertIn(b"RTF rescue", (self.base / "preview-data").read_bytes())
        notes = (self.base / "preview-notes").read_bytes()
        self.assertTrue(b"HTML" in notes and b"RTF verwendet" in notes)
        self.undo_calls()
        (self.base / "preview-data").unlink()
        self.run_cli(
            ["--from", "html", "--replace", "--preview-window", "--strict"], rc=3
        )
        self.assertTrue(
            not (self.base / "preview-data").exists()
            and self.undo_calls()
            == [
                "prepare",
                "cancel",
            ]
        )

    def test_parent_signal_terminates_native_preview(self):
        (self.base / "html").write_bytes(b"<p>valid</p>")
        for interruption, code in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            self.env["MOCK_PREVIEW_PAUSE"] = "1"
            (self.base / "preview-process").unlink(missing_ok=True)
            self.undo_calls()
            proc = subprocess.Popen(
                [*self.command, "--from", "html", "--replace", "--preview-window"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self.env,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 10
                while (
                    not (self.base / "preview-process").exists()
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                self.assertTrue((self.base / "preview-process").exists())
                child = int((self.base / "preview-process").read_text())
                proc.send_signal(interruption)
                out, error = proc.communicate(timeout=5)
                self.assertEqual(proc.returncode, code, (code, proc.returncode, error))
                self.assertTrue(not out and self.undo_calls() == ["prepare", "cancel"])
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("Vorschau-Kindprozess blieb aktiv")
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            self.env.pop("MOCK_PREVIEW_PAUSE")


class TerminalClipboardTests(CliTestCase):
    def setUp(self):
        super().setUp()
        if os.uname().sysname == "Darwin":
            self.env.update(MOCK_PLATFORM="Darwin")
        else:
            self.env.update(WAYLAND_DISPLAY="mock-wayland")
        del self.env["NO_CLIP"]

    def test_terminal_preview_accepts_rejects_or_reads_eof(self):
        (self.base / "plain").write_bytes(b"plain\n\n")
        for answer, expected_rc in ((b"nein\n", 4), (b"ja\n", 0), (b"\x04", 4)):
            self.undo_calls()
            (self.base / "written").write_bytes(b"protected")
            master, slave = pty.openpty()

            def terminal():
                os.setsid()
                fcntl.ioctl(2, termios.TIOCSCTTY, 0)

            proc = subprocess.Popen(
                [*self.command, "--plain", "--replace", "--preview"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=slave,
                env=self.env,
                # Der Kindprozess braucht ein eigenes kontrollierendes Terminal.
                preexec_fn=terminal,  # noqa: PLW1509
            )
            os.close(slave)
            captured = b""
            sent = False
            deadline = time.monotonic() + 20
            try:
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        captured += chunk
                        if not sent and b"[ja/Nein]" in captured:
                            os.write(master, answer)
                            sent = True
                    if proc.poll() is not None:
                        break
                self.assertTrue(sent, captured)
                self.assertEqual(proc.wait(timeout=2), expected_rc, captured)
                self.assertEqual(proc.stdout.read(), b"")
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait()
                proc.stdout.close()
                os.close(master)
            expected = (
                (self.base / "plain").read_bytes() if expected_rc == 0 else b"protected"
            )
            self.assertEqual((self.base / "written").read_bytes(), expected)
            self.assertEqual(
                self.undo_calls(),
                [
                    "prepare",
                    "replace" if expected_rc == 0 else "cancel",
                ],
            )

    def test_process_group_signals_cancel_prepared_undo(self):
        for interruption, expected_rc in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            self.undo_calls()
            proc = subprocess.Popen(
                [*self.command, "--stdin", "--plain", "--replace"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self.env,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    calls = self.base / "undo-calls"
                    if calls.exists() and calls.read_text().splitlines() == ["prepare"]:
                        break
                    time.sleep(0.01)
                else:
                    raise AssertionError("prepare wurde nicht erreicht")
                time.sleep(0.1)
                os.killpg(proc.pid, interruption)
                stdout, stderr = proc.communicate(timeout=5)
                self.assertEqual(
                    proc.returncode, expected_rc, (proc.returncode, stderr)
                )
                self.assertFalse(stdout)
                self.assertEqual(self.undo_calls(), ["prepare", "cancel"])
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()


if __name__ == "__main__":
    unittest.main()
