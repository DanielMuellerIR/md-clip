#!/usr/bin/env python3
"""Unit-Tests und optional echte Clipboard-Roundtrips in isoliertem Xvfb/sway."""
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "helpers" / "clipboard-undo-linux.py"
spec = importlib.util.spec_from_file_location("clipboard_undo_linux", HELPER)
undo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(undo)


class FakeClipboard:
    def __init__(self):
        self.epoch = 1
        self.data = {"html": b"<b>Original</b>", "binary": b"\0\xff", "empty": b""}
        self.failure = False
        self.write_failure = False
        self.writes = 0

    def stamp(self):
        return self.epoch

    def capture(self):
        if self.failure:
            raise undo.UndoError("Nicht lesbar")
        return self.epoch, self.data.copy()

    def text(self, data):
        return {"text": data}

    def publish(self, data):
        if self.write_failure:
            raise undo.UndoError("Nicht schreibbar", 3)
        self.writes += 1
        self.data = data.copy()
        self.epoch += 1
        return self.epoch


class StateTests(unittest.TestCase):
    def setUp(self):
        self.clip = FakeClipboard()
        self.now = 1000
        self.state = undo.State(self.clip, lambda: self.now)

    def replace(self):
        token = self.state.command("prepare")
        self.state.command("replace", token, b"**Markdown**")

    def test_all_formats_once(self):
        original = self.clip.data.copy()
        self.replace()
        self.state.command("undo")
        self.assertEqual(original, self.clip.data)
        with self.assertRaises(undo.UndoError):
            self.state.command("undo")
        self.assertEqual(2, self.clip.writes)

    def test_new_owner_with_identical_bytes_invalidates(self):
        self.replace()
        self.clip.epoch += 1
        with self.assertRaises(undo.UndoError):
            self.state.command("undo")
        self.assertIsNone(self.state.saved)
        self.assertEqual(1, self.clip.writes)

    def test_empty_snapshot(self):
        self.clip.data = {}
        self.replace()
        self.state.command("undo")
        self.assertEqual({}, self.clip.data)

    def test_change_before_replace(self):
        token = self.state.command("prepare")
        self.clip.epoch += 1
        with self.assertRaises(undo.UndoError):
            self.state.command("replace", token, b"new")
        self.assertEqual(0, self.clip.writes)

    def test_pending_busy_cancel_only_matching(self):
        token = self.state.command("prepare")
        with self.assertRaises(undo.UndoError):
            self.state.command("prepare")
        self.state.command("cancel", "wrong")
        self.assertIsNotNone(self.state.pending)
        self.state.command("cancel", token)
        self.assertIsNone(self.state.pending)
        self.assertEqual(0, self.clip.writes)

    def test_failed_prepare_preserves_prior_undo(self):
        original = self.clip.data.copy()
        self.replace()
        self.clip.failure = True
        with self.assertRaises(undo.UndoError):
            self.state.command("prepare")
        self.clip.failure = False
        self.state.command("undo")
        self.assertEqual(original, self.clip.data)

    def test_cancel_preserves_prior_undo(self):
        original = self.clip.data.copy()
        self.replace()
        token = self.state.command("prepare")
        self.state.command("cancel", token)
        self.state.command("undo")
        self.assertEqual(original, self.clip.data)

    def test_ttl_starts_at_commit(self):
        token = self.state.command("prepare")
        self.now += 599
        self.state.command("replace", token, b"new")
        self.now += 599
        self.state.command("undo")
        self.assertEqual(2, self.clip.writes)

    def test_ttl_boundary_and_pending_expiry(self):
        token = self.state.command("prepare")
        self.now += 600
        with self.assertRaises(undo.UndoError):
            self.state.command("replace", token, b"new")
        self.replace()
        self.now += 600
        self.state.expire()
        self.assertIsNone(self.state.saved)
        self.assertIsNone(self.state.pending)
        with self.assertRaises(undo.UndoError):
            self.state.command("undo")

    def test_invalid_utf8_never_writes(self):
        token = self.state.command("prepare")
        with self.assertRaises(undo.UndoError) as error:
            self.state.command("replace", token, b"\xff")
        self.assertEqual(3, error.exception.code)
        self.assertEqual(0, self.clip.writes)

    def test_failed_write_preserves_saved_snapshot(self):
        self.replace()
        token = self.state.command("prepare")
        self.clip.write_failure = True
        with self.assertRaises(undo.UndoError):
            self.state.command("replace", token, b"second")
        self.assertIsNotNone(self.state.saved)
        self.assertIsNone(self.state.pending)


class SecurityTests(unittest.TestCase):
    def test_private_directory_rejects_symlink_and_permissions(self):
        old = os.environ.get("XDG_RUNTIME_DIR")
        try:
            with tempfile.TemporaryDirectory() as root:
                os.chmod(root, 0o700)
                os.environ["XDG_RUNTIME_DIR"] = root
                path, fd = undo.private_directory()
                os.close(fd)
                self.assertEqual(0o700, os.stat(path).st_mode & 0o777)
                os.chmod(path, 0o755)
                with self.assertRaises(undo.UndoError):
                    undo.private_directory()
                os.chmod(path, 0o700)
                os.rmdir(path)
                os.symlink(root, path)
                with self.assertRaises(undo.UndoError):
                    undo.private_directory()
        finally:
            if old is None:
                os.environ.pop("XDG_RUNTIME_DIR", None)
            else:
                os.environ["XDG_RUNTIME_DIR"] = old

    def test_socket_rejects_regular_and_symlink(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "control.sock"
            path.write_text("unrelated")
            with self.assertRaises(undo.UndoError):
                undo.check_socket(path)
            path.unlink()
            path.symlink_to(Path(root) / "outside")
            with self.assertRaises(undo.UndoError):
                undo.check_socket(path)

    def test_wayland_strings_preserve_names(self):
        for name in ("text/plain;charset=utf-8", "application/x-äö", "zero"):
            encoded = undo.pack_string(name)
            decoded, end = undo.unpack_string(encoded)
            self.assertEqual(name, decoded)
            self.assertEqual(len(encoded), end)
        for raw in (b"", b"\x00\x00\x00\x00", b"\xff\xff\xff\xff"):
            with self.assertRaises(undo.UndoError):
                undo.unpack_string(raw)


class NativeRepresentationTests(unittest.TestCase):
    def test_x11_32bit_words_use_native_long_slots(self):
        class Transport:
            def XChangeProperty(self, display, window, prop, typ, fmt, mode, ptr, count):
                self.format = fmt
                self.values = [undo.C.cast(ptr, undo.C.POINTER(undo.UL))[i] for i in range(count)]
        clip = undo.X11.__new__(undo.X11)
        clip.x, clip.display = Transport(), None
        raw = b"\x01\x00\x00\x00\xff\xff\xff\xff"
        if sys.byteorder != "little":
            raw = b"\x00\x00\x00\x01\xff\xff\xff\xff"
        clip.put(1, 2, 3, 32, raw)
        self.assertEqual(32, clip.x.format)
        self.assertEqual([1, 0xffffffff], clip.x.values)

    def test_xclip_incr_capability_is_not_a_payload_format(self):
        clip = undo.X11.__new__(undo.X11)
        clip.targets, clip.timestamp, clip.multiple, clip.incr = 1, 2, 3, 4
        clip.atom_type, clip.window = 11, 999
        names = {"SAVE_TARGETS": 6, "DELETE": 7, "INSERT_SELECTION": 8, "INSERT_PROPERTY": 9}
        clip.atom = lambda name: names[name]
        clip.stamp = lambda: (1, 42)
        requested = []
        def convert(target, deadline, limit):
            requested.append(target)
            if target == clip.targets:
                return 11, 32, undo.struct.pack("=6I", 1, 2, 3, 4, 6, 10)
            return 12, 8, b"opaque\x00data"
        clip._convert = convert
        stamp, snapshot = clip.capture()
        self.assertEqual((1, 42), stamp)
        self.assertEqual({10: (12, 8, b"opaque\x00data")}, snapshot)
        self.assertEqual([1, 10], requested)

    def test_dead_foreign_x11_window_does_not_poison_transfer(self):
        clip = undo.X11.__new__(undo.X11)
        clip.window, clip.read_window, clip.errors = 123, 456, False
        error = undo.XError(0, None, 789, 0, 3, 18, 0)
        clip._error(None, undo.C.byref(error))
        self.assertFalse(clip.errors)
        error.resourceid = clip.read_window
        clip._error(None, undo.C.byref(error))
        self.assertTrue(clip.errors)

    def test_wayland_fd_precedes_its_send_message_in_a_batch(self):
        sender, receiver = undo.socket.socketpair()
        read_fd, write_fd = os.pipe()
        clip = undo.Wayland.__new__(undo.Wayland)
        clip.sock, clip.message, clip.fds = receiver, bytearray(), []
        clip.objects = {2: "callback", 10: "source"}
        clip.completed, clip.writes = set(), {}
        clip.sources = {10: {"binary": b"\x00\xffpayload"}}
        callback = undo.struct.pack("=III", 2, 12 << 16, 0)
        body = undo.pack_string("binary")
        message = undo.struct.pack("=II", 10, (8 + len(body)) << 16) + body
        try:
            sender.sendmsg([callback + message], [(undo.socket.SOL_SOCKET, undo.socket.SCM_RIGHTS,
                                                  undo.array.array("i", [write_fd]))])
            os.close(write_fd)
            write_fd = None
            clip._read(time.monotonic() + 1)
            self.assertEqual(1, len(clip.fds))
            clip._read(time.monotonic() + 1)
            self.assertEqual([], clip.fds)
            clip._pump_writes()
            self.assertEqual(b"\x00\xffpayload", os.read(read_fd, 100))
            self.assertEqual(b"", os.read(read_fd, 1))
        finally:
            if write_fd is not None:
                os.close(write_fd)
            os.close(read_fd)
            for fd in clip.fds:
                os.close(fd)
            for fd in clip.writes:
                os.close(fd)
            sender.close()
            receiver.close()

    def test_wayland_empty_and_binary_send_close_fd(self):
        clip = undo.Wayland.__new__(undo.Wayland)
        clip.objects = {10: "source"}
        clip.sources = {10: {"empty": b"", "binary": b"\x00\xffdata"}}
        clip.writes = {}
        for name, expected in clip.sources[10].items():
            read_fd, write_fd = os.pipe()
            fds = [write_fd]
            clip._event(10, 0, undo.pack_string(name), fds)
            self.assertEqual([], fds)
            clip._pump_writes()
            try:
                self.assertEqual(expected, os.read(read_fd, 100))
                self.assertEqual(b"", os.read(read_fd, 1))
            finally:
                os.close(read_fd)
        self.assertEqual({}, clip.writes)


def fixture(clip, size=2 * 1024 * 1024):
    data = {
        "text/plain;charset=utf-8": "Text äö😀\n".encode(),
        "text/html": b"<b>Text</b>\x00tail",
        "text/rtf": b"{\\rtf1\\b Text}",
        "image/png": b"\x89PNG\r\n\x1a\n\x00\xff\x10",
        "application/x-md-clip-empty": b"",
        "application/x-md-clip-opaque": bytes(range(256)) * 4,
        "application/x-md-clip-large": b"a\x00b\xff" * (size // 4),
    }
    if isinstance(clip, undo.X11):
        result = {clip.atom(name): (clip.atom(name), 8, value) for name, value in data.items()}
        result[clip.atom("application/x-md-clip-16")] = clip.atom("MD_CLIP_SHORT"), 16, b"\x00\x01\xff\xff\x20\x30"
        result[clip.atom("application/x-md-clip-32")] = clip.atom("MD_CLIP_LONG"), 32, b"\x00\x00\x00\x01\xff\xff\xff\xff"
        return result
    return data


def source():
    clip = undo.backend()
    held = []
    delayed = False
    if isinstance(clip, undo.Wayland):
        original = clip._event
        def event(obj, opcode, data, fds):
            if delayed and clip.objects.get(obj) == "source" and opcode == 0:
                if fds:
                    held.append(fds.pop(0))
            else:
                original(obj, opcode, data, fds)
        clip._event = event
    else:
        transfers = {}
        original_serve, original_put = clip._serve, clip.put
        def serve(requestor, target, prop):
            value = clip._value(target)
            if value and len(value[2]) > clip.chunk:
                transfers[(requestor, prop)] = {"expected": len(value[2]), "sent": 0, "chunks": 0,
                                                "eof": False, "started": time.monotonic()}
            return original_serve(requestor, target, prop)
        def put(window, prop, typ, fmt, data):
            stats = transfers.get((window, prop))
            if stats is not None and typ != clip.incr:
                stats["sent"] += len(data)
                stats["chunks"] += 1
                stats["eof"] = not data
                stats["elapsed"] = round(time.monotonic() - stats["started"], 3)
            return original_put(window, prop, typ, fmt, data)
        clip._serve, clip.put = serve, put
        original = clip._request
        def request(req):
            if not delayed:
                original(req)
        clip._request = request
    clip.publish(fixture(clip))
    print("ready", flush=True)
    try:
        while True:
            clip.pump(.02)
            if not select.select([sys.stdin], [], [], 0)[0]:
                continue
            command = sys.stdin.readline().strip()
            if command == "quit" or not command:
                break
            if command == "stats":
                if isinstance(clip, undo.X11):
                    values = list(transfers.values())[-5:]
                    for stats in values:
                        stats["active"] = any(info[2] and len(info[2]) == stats["expected"] for info in clip.outgoing.values())
                    state = {"transfers": values, "errors": clip.errors,
                             "last_error": getattr(clip, "last_error", None),
                             "active": [{"size": len(item[2]), "position": item[3],
                                         "remaining": round(item[4] - time.monotonic(), 3)}
                                        for item in clip.outgoing.values()]}
                    print(json.dumps(state), file=sys.stderr, flush=True)
            elif command == "delay":
                delayed = True
            else:
                delayed = False
                for fd in held:
                    os.close(fd)
                held.clear()
                if command == "empty":
                    clip.publish({})
                elif command == "oversize":
                    clip.publish(fixture(clip, 65 * 1024 * 1024))
                elif command == "converted":
                    clip.publish(clip.text(b"new"))
                else:
                    clip.publish(fixture(clip))
            print("ready", flush=True)
    finally:
        for fd in held:
            os.close(fd)
        clip.close()


@unittest.skipUnless("--integration" in sys.argv, "benötigt isolierte Linux-Clipboard-Sitzung")
class NativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != "linux":
            raise unittest.SkipTest("Linux benötigt")
        if not os.environ.get("MD_CLIP_UNDO_TEST_ISOLATED"):
            raise unittest.SkipTest("MD_CLIP_UNDO_TEST_ISOLATED=1 für Xvfb/sway-Test erforderlich")
        check = subprocess.run([sys.executable, str(HELPER), "available"], capture_output=True, timeout=10)
        if check.returncode:
            raise RuntimeError(check.stderr.decode())

    def setUp(self):
        self.run_helper("stop", expected=0)
        self.publisher = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--source"],
                                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                          text=True, bufsize=1)
        self.wait_ready()

    def tearDown(self):
        try:
            self.run_helper("stop", expected=0)
        finally:
            if self.publisher.poll() is None:
                try:
                    self.publisher.stdin.write("quit\n")
                    self.publisher.stdin.flush()
                except BrokenPipeError:
                    pass
            try:
                self.publisher.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                self.publisher.kill()
                self.publisher.communicate()

    def wait_ready(self):
        if not select.select([self.publisher.stdout], [], [], 10)[0]:
            self.fail("Test-Clipboard-Eigentümer antwortet nicht")
        answer = self.publisher.stdout.readline().strip()
        if answer != "ready":
            self.fail("Test-Clipboard-Eigentümer abgebrochen: " + self.publisher.stderr.read())

    def source_command(self, command):
        self.publisher.stdin.write(command + "\n")
        self.publisher.stdin.flush()
        self.wait_ready()

    def run_helper(self, command, token=None, data=None, expected=0):
        args = [sys.executable, str(HELPER), command]
        if token is not None:
            args.append(token)
        result = subprocess.run(args, input=data, capture_output=True, timeout=40)
        message = result.stderr.decode()
        if result.returncode != expected and hasattr(self, "publisher") and self.publisher.poll() is None and not os.environ.get("WAYLAND_DISPLAY"):
            self.source_command("stats")
            if select.select([self.publisher.stderr], [], [], 1)[0]:
                message += " Sender: " + self.publisher.stderr.readline().strip()
        self.assertEqual(expected, result.returncode, message)
        return result.stdout.decode().strip()

    def read_clipboard(self):
        clip = undo.backend()
        try:
            _, snapshot = clip.capture()
            return snapshot
        except undo.UndoError as error:
            if isinstance(clip, undo.X11) and self.publisher.poll() is None:
                self.source_command("stats")
                if select.select([self.publisher.stderr], [], [], 1)[0]:
                    stats = self.publisher.stderr.readline().strip()
                    raise undo.UndoError(str(error) + " Sender: " + stats, error.code)
            raise
        finally:
            clip.close()

    def test_complete_binary_and_native_formats_once(self):
        original = self.read_clipboard()
        token = self.run_helper("prepare")
        self.run_helper("replace", token, b"**converted**\n")
        after = self.read_clipboard()
        self.assertNotEqual(original, after)
        self.run_helper("undo")
        self.assertEqual(original, self.read_clipboard())
        self.run_helper("undo", expected=1)
        self.assertEqual(original, self.read_clipboard())

    def test_identical_external_copy_invalidates_undo(self):
        token = self.run_helper("prepare")
        self.run_helper("replace", token, b"new")
        before = self.read_clipboard()
        self.source_command("converted")
        copied = self.read_clipboard()
        self.assertEqual(before, copied)
        self.run_helper("undo", expected=1)
        self.assertEqual(copied, self.read_clipboard())

    def test_undo_from_another_installation(self):
        original = self.read_clipboard()
        token = self.run_helper("prepare")
        self.run_helper("replace", token, b"new")
        with tempfile.TemporaryDirectory(prefix="md-clip-other-install-") as directory:
            other = Path(directory) / "clipboard-undo-linux.py"
            shutil.copyfile(HELPER, other)
            result = subprocess.run([sys.executable, str(other), "undo"],
                                    capture_output=True, timeout=40)
            self.assertEqual(0, result.returncode, result.stderr.decode())
        self.assertEqual(original, self.read_clipboard())
        self.run_helper("undo", expected=1)
        self.assertEqual(original, self.read_clipboard())

    def test_same_owner_reoffers_identical_bytes_before_replace(self):
        token = self.run_helper("prepare")
        self.source_command("republish")
        self.run_helper("replace", token, b"new", expected=1)
        clip = undo.backend()
        try:
            self.assertEqual(self.read_clipboard(), fixture(clip))
        finally:
            clip.close()

    def test_empty_initial_clipboard(self):
        self.source_command("empty")
        self.assertEqual({}, self.read_clipboard())
        token = self.run_helper("prepare")
        self.run_helper("replace", token, b"new")
        self.run_helper("undo")
        self.assertEqual({}, self.read_clipboard())

    def test_cancel_and_concurrent_prepare(self):
        original = self.read_clipboard()
        token = self.run_helper("prepare")
        self.run_helper("prepare", expected=1)
        self.run_helper("cancel", "wrong")
        self.run_helper("prepare", expected=1)
        self.run_helper("cancel", token)
        self.assertEqual(original, self.read_clipboard())
        token = self.run_helper("prepare")
        self.run_helper("cancel", token)

    def test_delayed_capture_aborts_without_write(self):
        self.source_command("delay")
        start = time.monotonic()
        self.run_helper("prepare", expected=1)
        self.assertLess(time.monotonic() - start, 8)
        self.source_command("republish")
        original = self.read_clipboard()
        self.run_helper("undo", expected=1)
        self.assertEqual(original, self.read_clipboard())

    def test_owner_change_during_capture_aborts(self):
        self.source_command("delay")
        prepare = subprocess.Popen([sys.executable, str(HELPER), "prepare"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(.2)
        self.source_command("republish")
        stdout, stderr = prepare.communicate(timeout=10)
        self.assertEqual(1, prepare.returncode, stderr.decode())
        self.assertEqual(b"", stdout)
        self.run_helper("undo", expected=1)

    def test_oversize_capture_rejected(self):
        self.source_command("oversize")
        self.run_helper("prepare", expected=1)
        self.run_helper("undo", expected=1)

    def test_dependencies_without_display(self):
        environment = os.environ.copy()
        environment.pop("DISPLAY", None)
        environment.pop("WAYLAND_DISPLAY", None)
        environment.pop("XDG_RUNTIME_DIR", None)
        result = subprocess.run([sys.executable, str(HELPER), "dependencies"],
                                env=environment, capture_output=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr.decode())

    def test_available_reads_no_formats(self):
        self.source_command("delay")
        start = time.monotonic()
        self.run_helper("available")
        self.assertLess(time.monotonic() - start, 2)
        self.source_command("republish")

    def test_only_socket_is_persisted(self):
        token = self.run_helper("prepare")
        self.run_helper("replace", token, b"sensitive-test-data")
        path, fd = undo.private_directory()
        os.close(fd)
        self.assertEqual(["control.sock"], os.listdir(path))
        self.run_helper("undo")

    def test_bad_socket_request_preserves_saved_undo(self):
        original = self.read_clipboard()
        token = self.run_helper("prepare")
        self.run_helper("replace", token, b"new")
        path, fd = undo.private_directory()
        os.close(fd)
        for request in (b"x", b"[]", b"null", b'{"command":[]}'):
            connection = undo.connect(os.path.join(path, "control.sock"))
            with connection:
                connection.sendall(len(request).to_bytes(4, "big") + request)
                response = json.loads(connection.recv(1024))
                self.assertEqual(2, response["code"])
        self.run_helper("undo")
        self.assertEqual(original, self.read_clipboard())

    def test_stop_preserves_external_owner(self):
        self.run_helper("prepare")
        self.run_helper("stop")
        self.assertTrue(self.read_clipboard())


if __name__ == "__main__":
    if "--source" in sys.argv:
        source()
    else:
        unittest.main(argv=[sys.argv[0]])
