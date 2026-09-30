#!/usr/bin/env python3
"""Compare-Verträge mit isolierten Werkzeugen, ohne System-Clipboard oder GUI."""

import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

PROJECT = Path(__file__).resolve().parents[1]


def executable(destination, content):
    destination.write_text(content)
    destination.chmod(0o755)


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="md-clip-compare-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "project"
        for folder in ("tests", "helpers", "bin", "lib"):
            (self.repo / folder).mkdir(parents=True)
        for name in ("compare.sh", "compare-file.sh", "load-clipboard.swift"):
            shutil.copy2(PROJECT / "tests" / name, self.repo / "tests" / name)
        for name in ("clipboard-html.swift", "clipboard-rtf.swift"):
            shutil.copy2(PROJECT / "helpers" / name, self.repo / "helpers" / name)
        for name in ("pipeline.sh", "tidy-markdown.pl", "tables.lua"):
            shutil.copy2(PROJECT / "lib" / name, self.repo / "lib" / name)
        self.fake = self.root / "tools"
        self.fake.mkdir()
        self.clipboard = self.root / "clipboard"
        self.clipboard.write_bytes(b"Source\n\n")
        self.html = self.root / "html"
        self.html.write_bytes(b"<p>Source</p>\n\n")
        self.rtf = self.root / "rtf"
        self.rtf.write_bytes(b"{\\rtf1 Source}\n\n")
        self.compile_log = self.root / "compile.log"
        self.write_log = self.root / "write.log"
        self.env = {
            **os.environ,
            "PATH": f"{self.fake}:{os.environ['PATH']}",
            "BASENAME_OVERRIDE": "sample",
            "TEST_CLIPBOARD": str(self.clipboard),
            "TEST_HTML": str(self.html),
            "TEST_RTF": str(self.rtf),
            "TEST_COMPILE_LOG": str(self.compile_log),
            "TEST_WRITE_LOG": str(self.write_log),
        }
        for key in ("CAPTURE_APPLEMD_MANUAL", "MD_CLIP_COMPARE_RUNTIME"):
            self.env.pop(key, None)
        executable(self.fake / "pbpaste", '#!/bin/sh\ncat "$TEST_CLIPBOARD"\n')
        executable(self.fake / "pbcopy", '#!/bin/sh\necho pbcopy >> "$TEST_WRITE_LOG"\ncat > "$TEST_CLIPBOARD"\n')
        executable(self.fake / "osascript", "#!/bin/sh\nexit 0\n")
        for kind in ("html", "rtf"):
            executable(self.repo / "helpers" / f"clipboard-{kind}",
                       f'#!/bin/sh\ncat "$TEST_{kind.upper()}"\n')
        executable(self.repo / "bin" / "md-clip", '''#!/bin/sh
if [ "${TEST_CONVERSION_STATUS:-0}" != 0 ]; then
  printf 'partial result\n'
  echo 'Konvertierung fehlgeschlagen' >&2
  exit "$TEST_CONVERSION_STATUS"
fi
if [ "${TEST_REQUIRE_READERS:-0}" = 1 ]; then
  runtime=$(dirname "$0")
  for reader in clipboard-html clipboard-rtf; do
    [ -x "$runtime/$reader" ] || exit 2
    "$runtime/$reader" >/dev/null || exit 2
  done
  for resource in pipeline.sh tidy-markdown.pl tables.lua; do
    [ -f "$runtime/$resource" ] || exit 2
  done
fi
printf 'Markdown\n\n'
''')
        executable(self.fake / "swiftc", '''#!/bin/sh
src=$1
printf '%s\n' "${src##*/}" >> "$TEST_COMPILE_LOG"
[ "${TEST_COMPILE_FAIL:-}" != "${src##*/}" ] || exit 7
shift
[ "$1" = -o ] || exit 8
out=$2
case "${src##*/}" in
  clipboard-html.swift) printf '#!/bin/sh\ncat "$TEST_HTML"\n' > "$out" ;;
  clipboard-rtf.swift) printf '#!/bin/sh\ncat "$TEST_RTF"\n' > "$out" ;;
  load-clipboard.swift) printf '#!/bin/sh\necho loader >> "$TEST_WRITE_LOG"\ncat "$2" > "$TEST_CLIPBOARD"\n' > "$out" ;;
  *) exit 9 ;;
esac
chmod +x "$out"
''')

    def run_compare(self, filename=None, manual=None):
        script = "compare-file.sh" if filename else "compare.sh"
        args = ["bash", str(self.repo / "tests" / script)]
        if filename:
            args.append(str(filename))
        if manual is None:
            result = subprocess.run(args, env=self.env, capture_output=True, timeout=10)
            return result.returncode, result.stdout + result.stderr
        env = {**self.env, "CAPTURE_APPLEMD_MANUAL": "1"}
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(args[0], args, env)
        output = bytearray()
        deadline = time.monotonic() + 10
        answered = False
        child_active = True
        try:
            while time.monotonic() < deadline:
                if not select.select([fd], [], [], 0.1)[0]:
                    continue
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
                if b"Dann hier Enter" in output and not answered:
                    self.clipboard.write_bytes(manual)
                    os.write(fd, b"\n")
                    answered = True
            else:
                self.fail("Compare-PTY hat seine Frist überschritten")
            waited, status = os.waitpid(pid, os.WNOHANG)
            if not waited:
                # EOF am PTY kann dem Prozessende knapp vorausgehen.
                while time.monotonic() < deadline:
                    waited, status = os.waitpid(pid, os.WNOHANG)
                    if waited:
                        break
                    time.sleep(0.01)
            self.assertEqual(waited, pid, "Compare-Prozess beendet sich nicht")
            child_active = False
            return os.waitstatus_to_exitcode(status), bytes(output)
        finally:
            if child_active:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(fd)

    def capture(self, suffix):
        return self.repo / "tests" / "captures" / f"sample.{suffix}"

    def test_capture_preserves_rich_and_markdown_bytes(self):
        status, output = self.run_compare()
        self.assertEqual(status, 0, output)
        self.assertEqual(self.capture("html").read_bytes(), self.html.read_bytes())
        self.assertEqual(self.capture("rtf").read_bytes(), self.rtf.read_bytes())
        self.assertEqual(self.capture("mdclip.md").read_bytes(), b"Markdown\n\n")

    def test_conversion_failure_stops_before_manual_prompt(self):
        self.env.update(TEST_CONVERSION_STATUS="3", CAPTURE_APPLEMD_MANUAL="1")
        self.capture("mdclip.md").parent.mkdir()
        self.capture("mdclip.md").write_bytes(b"previous successful capture\n")
        status, output = self.run_compare()
        self.assertEqual(status, 3, output)
        self.assertNotIn(b"JETZT manuell", output)
        self.assertIn(b"Konvertierung fehlgeschlagen", output)
        self.assertEqual(self.capture("mdclip.md").read_bytes(), b"previous successful capture\n")

    def test_identical_manual_output_is_saved_with_all_newlines(self):
        original = self.clipboard.read_bytes()
        status, output = self.run_compare(manual=original)
        self.assertEqual(status, 0, output)
        self.assertEqual(self.capture("applemd.md").read_bytes(), original)
        self.assertNotIn(b"wahrscheinlich nichts", output)

    def test_different_manual_output_is_saved_with_all_newlines(self):
        apple = b"**Apple**\n\n\n"
        status, output = self.run_compare(manual=apple)
        self.assertEqual(status, 0, output)
        self.assertEqual(self.capture("applemd.md").read_bytes(), apple)

    def test_empty_manual_output_is_rejected(self):
        status, output = self.run_compare(manual=b"")
        self.assertNotEqual(status, 0, output)
        self.assertFalse(self.capture("applemd.md").exists())

    def test_file_compare_builds_readers_in_clean_checkout(self):
        for helper in self.repo.glob("helpers/clipboard-*"):
            if helper.suffix != ".swift":
                helper.unlink()
        fixture = self.root / "sample.html"
        fixture.write_bytes(self.html.read_bytes())
        self.env["TEST_REQUIRE_READERS"] = "1"
        status, output = self.run_compare(filename=fixture)
        self.assertEqual(status, 0, output)
        self.assertEqual(set(self.compile_log.read_text().splitlines()),
                         {"load-clipboard.swift", "clipboard-html.swift", "clipboard-rtf.swift"})
        self.assertEqual(self.capture("html").read_bytes(), self.html.read_bytes())
        self.assertEqual(self.capture("mdclip.md").read_bytes(), b"Markdown\n\n")
        self.assertFalse((self.repo / "helpers" / "clipboard-html").exists())

    @unittest.skipUnless(shutil.which("pandoc"), "Pipeline-Test benötigt pandoc")
    def test_file_compare_uses_real_product_and_pipeline(self):
        shutil.copy2(PROJECT / "bin" / "md-clip", self.repo / "bin" / "md-clip")
        # Nur das macOS-Clipboard wird simuliert; Konverter und Ressourcen sind echt.
        executable(self.fake / "uname", "#!/bin/sh\nprintf 'Darwin\\n'\n")
        fixture = self.root / "sample.html"
        fixture.write_bytes(self.html.read_bytes())
        status, output = self.run_compare(filename=fixture)
        self.assertEqual(status, 0, output)
        self.assertEqual(self.capture("mdclip.md").read_bytes(), b"Source\n")

    def test_reader_build_failure_does_not_write_clipboard(self):
        fixture = self.root / "sample.html"
        fixture.write_bytes(self.html.read_bytes())
        self.env["TEST_COMPILE_FAIL"] = "clipboard-rtf.swift"
        status, output = self.run_compare(filename=fixture)
        self.assertEqual(status, 7, output)
        self.assertFalse(self.write_log.exists())

    def test_unknown_extension_does_not_build_or_write(self):
        fixture = self.root / "sample.pdf"
        fixture.write_bytes(b"unsupported")
        status, output = self.run_compare(filename=fixture)
        self.assertEqual(status, 2, output)
        self.assertFalse(self.compile_log.exists())
        self.assertFalse(self.write_log.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
