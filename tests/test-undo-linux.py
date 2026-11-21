#!/usr/bin/env python3
"""Unit-Tests und optional echte Clipboard-Roundtrips in isoliertem Xvfb/sway."""
import array
from collections import deque
import ctypes
from dataclasses import asdict
import json
import os
from pathlib import Path
import select
import signal
import socket
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, Mock, call, patch

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "helpers" / "clipboard-undo-linux.py"
sys.path.insert(0, str(HELPER.parent))

from clipboard_undo import backends, cli, daemon, wayland, x11
from clipboard_undo.common import UndoError
from clipboard_undo.state import State
from clipboard_undo.wayland import Wayland
from clipboard_undo.x11 import X11, X11Format, X11Stamp


class DiagnoseTests(unittest.TestCase):
    def test_no_session_needs_no_clipboard(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(backends, 'dependencies'), \
             patch.object(backends, 'backend') as backend, patch.object(daemon, 'private_directory') as directory:
            self.assertEqual('x11-session-missing', backends.diagnose())
            backend.assert_not_called()
            directory.assert_not_called()

    def test_probe_closes_without_creating_daemon_state(self):
        with patch.dict(os.environ, {'DISPLAY': ':test'}, clear=True), patch.object(backends, 'dependencies'), \
             patch.object(backends, 'backend') as backend, patch.object(daemon, 'private_directory') as directory:
            self.assertEqual('ok', backends.diagnose())
            backend.assert_called_once_with(probe=True)
            backend.return_value.close.assert_called_once_with()
            directory.assert_not_called()

    def test_library_and_protocol_causes(self):
        for reason in ('x11-libraries-missing', 'wayland-data-control-missing', 'wayland-seat-unsupported'):
            with patch.dict(os.environ, {'DISPLAY': ':test'}, clear=True), patch.object(backends, 'dependencies'), \
                 patch.object(backends, 'backend', side_effect=UndoError('private error', 2, reason)):
                self.assertEqual(reason, backends.diagnose())

    def test_wayland_registry_capabilities_without_selection_binding(self):
        for interfaces, reason in ((['wl_seat'], 'wayland-data-control-missing'),
                                   (['zwlr_data_control_manager_v1'], 'wayland-seat-unsupported'),
                                   (['zwlr_data_control_manager_v1', 'wl_seat', 'wl_seat'], 'wayland-seat-unsupported'),
                                   (['ext_data_control_manager_v1', 'wl_seat'], None)):
            def registry(clipboard):
                clipboard.globals = {i + 1: wayland.Global(name, 1) for i, name in enumerate(interfaces)}
            with patch.dict(os.environ, {'WAYLAND_DISPLAY': 'test', 'XDG_RUNTIME_DIR': '/tmp'}, clear=True), \
                 patch.object(socket, 'socket'), patch.object(Wayland, 'sync', registry), \
                 patch.object(Wayland, 'send') as send, patch.object(Wayland, 'bind') as bind:
                if reason:
                    with self.assertRaises(UndoError) as error:
                        Wayland(probe=True)
                    self.assertEqual(reason, error.exception.reason)
                else:
                    clipboard = Wayland(probe=True)
                    clipboard.close()
                send.assert_called_once()
                self.assertEqual((1, 1), send.call_args[0][:2])  # Nur get_registry.
                bind.assert_not_called()

    def test_runtime_is_checked_without_creating_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = {'WAYLAND_DISPLAY': 'test', 'XDG_RUNTIME_DIR': directory}
            os.chmod(directory, 0o755)
            with patch.dict(os.environ, environment, clear=True), patch.object(backends, 'dependencies'), \
                 patch.object(backends, 'backend') as backend:
                self.assertEqual('runtime-unsafe', backends.diagnose())
                backend.assert_not_called()
                self.assertEqual([], os.listdir(directory))
        with patch.dict(os.environ, {'WAYLAND_DISPLAY': 'test'}, clear=True), patch.object(backends, 'dependencies'):
            self.assertEqual('wayland-runtime-missing', backends.diagnose())


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
            raise UndoError("Nicht lesbar")
        return self.epoch, self.data.copy()

    def text(self, data):
        return {"text": data}

    def publish(self, data):
        if self.write_failure:
            raise UndoError("Nicht schreibbar", 3)
        self.writes += 1
        self.data = data.copy()
        self.epoch += 1
        return self.epoch


class StateTests(unittest.TestCase):
    def setUp(self):
        self.clip = FakeClipboard()
        self.now = 1000
        self.state = State(self.clip, lambda: self.now)

    def replace(self):
        token = self.state.command("prepare")
        self.state.command("replace", token, b"**Markdown**")

    def test_status_preserves_pending_and_saved_without_materializing(self):
        token = self.state.command("prepare")
        self.clip.failure = True
        status = json.loads(self.state.command("status", token))
        self.assertEqual({"version": 1, "undo_available": False, "pending_valid": True}, status)
        self.assertFalse(json.loads(self.state.command("status", "wrong"))["pending_valid"])
        self.state.command("replace", token, b"Markdown")
        self.assertEqual({"version": 1, "undo_available": True, "pending_valid": False},
                         json.loads(self.state.command("status")))
        self.state.command("undo")
        self.assertFalse(json.loads(self.state.command("status"))["undo_available"])

    def test_status_rejects_changed_and_expired_generations(self):
        self.replace()
        token = self.state.command("prepare")
        self.clip.epoch += 1
        self.assertEqual({"version": 1, "undo_available": False, "pending_valid": False},
                         json.loads(self.state.command("status", token)))
        self.replace()
        token = self.state.command("prepare")
        self.now += 600
        self.assertFalse(json.loads(self.state.command("status", token))["pending_valid"])
        self.assertFalse(json.loads(self.state.command("status"))["undo_available"])

    def test_all_formats_once(self):
        original = self.clip.data.copy()
        self.replace()
        self.state.command("undo")
        self.assertEqual(original, self.clip.data)
        with self.assertRaises(UndoError):
            self.state.command("undo")
        self.assertEqual(2, self.clip.writes)

    def test_new_owner_with_identical_bytes_invalidates(self):
        self.replace()
        self.clip.epoch += 1
        with self.assertRaises(UndoError):
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
        with self.assertRaises(UndoError):
            self.state.command("replace", token, b"new")
        self.assertEqual(0, self.clip.writes)

    def test_pending_busy_cancel_only_matching(self):
        token = self.state.command("prepare")
        with self.assertRaises(UndoError):
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
        with self.assertRaises(UndoError):
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
        with self.assertRaises(UndoError):
            self.state.command("replace", token, b"new")
        self.replace()
        self.now += 600
        self.state.expire()
        self.assertIsNone(self.state.saved)
        self.assertIsNone(self.state.pending)
        with self.assertRaises(UndoError):
            self.state.command("undo")

    def test_invalid_utf8_never_writes(self):
        token = self.state.command("prepare")
        with self.assertRaises(UndoError) as error:
            self.state.command("replace", token, b"\xff")
        self.assertEqual(3, error.exception.code)
        self.assertEqual(0, self.clip.writes)

    def test_failed_write_preserves_saved_snapshot(self):
        self.replace()
        token = self.state.command("prepare")
        self.clip.write_failure = True
        with self.assertRaises(UndoError):
            self.state.command("replace", token, b"second")
        self.assertIsNotNone(self.state.saved)
        self.assertIsNone(self.state.pending)


class SecurityTests(unittest.TestCase):
    def test_fresh_status_creates_no_service_directory(self):
        with tempfile.TemporaryDirectory() as root:
            environment = dict(os.environ, XDG_RUNTIME_DIR=root, DISPLAY=":fresh-status", WAYLAND_DISPLAY="")
            result = subprocess.run([sys.executable, str(HELPER), "status", "unused"],
                                    env=environment, capture_output=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual({"version": 1, "undo_available": False, "pending_valid": False}, json.loads(result.stdout))
            self.assertEqual([], os.listdir(root))

    def test_private_directory_rejects_symlink_and_permissions(self):
        old = os.environ.get("XDG_RUNTIME_DIR")
        try:
            with tempfile.TemporaryDirectory() as root:
                os.chmod(root, 0o700)
                os.environ["XDG_RUNTIME_DIR"] = root
                path, fd = daemon.private_directory()
                os.close(fd)
                self.assertEqual(0o700, os.stat(path).st_mode & 0o777)
                os.chmod(path, 0o755)
                with self.assertRaises(UndoError):
                    daemon.private_directory()
                os.chmod(path, 0o700)
                os.rmdir(path)
                os.symlink(root, path)
                with self.assertRaises(UndoError):
                    daemon.private_directory()
        finally:
            if old is None:
                os.environ.pop("XDG_RUNTIME_DIR", None)
            else:
                os.environ["XDG_RUNTIME_DIR"] = old

    def test_socket_rejects_regular_and_symlink(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "control.sock"
            path.write_text("unrelated")
            with self.assertRaises(UndoError):
                daemon.check_socket(path)
            path.unlink()
            path.symlink_to(Path(root) / "outside")
            with self.assertRaises(UndoError):
                daemon.check_socket(path)

    def test_wayland_strings_preserve_names(self):
        for name in ("text/plain;charset=utf-8", "application/x-äö", "zero"):
            encoded = wayland.pack_string(name)
            decoded, end = wayland.unpack_string(encoded)
            self.assertEqual(name, decoded)
            self.assertEqual(len(encoded), end)
        for raw in (b"", b"\x00\x00\x00\x00", b"\xff\xff\xff\xff"):
            with self.assertRaises(UndoError):
                wayland.unpack_string(raw)


class ResourceLifetimeTests(unittest.TestCase):
    def test_prepare_restarts_daemon_after_lock_collision(self):
        connection = MagicMock()
        connection.recv.return_value = b'{"code":0,"result":"new-token"}\n'
        first = Mock()
        first.poll.return_value = 0
        with patch.object(cli, 'private_directory', return_value=('/synthetic', -1)), \
             patch.object(cli.os, 'close'), patch.object(cli.time, 'sleep'), \
             patch.object(cli.time, 'monotonic', side_effect=[0, 0.05]), \
             patch.object(cli, 'connect', side_effect=[FileNotFoundError, ConnectionRefusedError, connection]), \
             patch.object(cli.subprocess, 'Popen', side_effect=[first, Mock()]) as start:
            self.assertEqual(cli.client('helper.py', 'prepare'), 'new-token')
        self.assertEqual(start.call_count, 2)

    def test_wayland_initial_selection_failure_closes_socket_and_received_fds(self):
        with tempfile.TemporaryDirectory() as directory, \
             socket.socket(socket.AF_UNIX) as listener, socket.socket(socket.AF_UNIX) as client:
            listener.bind(os.path.join(directory, "test"))
            listener.listen()
            queued_read, queued_write = os.pipe()
            transfer_read, transfer_write = os.pipe()
            environment = {"WAYLAND_DISPLAY": "test", "XDG_RUNTIME_DIR": directory}

            def enter_registry(clipboard):
                clipboard.globals = {
                    1: wayland.Global(wayland.WLR_MANAGER, 2),
                    2: wayland.Global(wayland.SEAT_INTERFACE, 1),
                }

            def fail_selection(clipboard):
                clipboard.fds.append(queued_write)
                clipboard.writes[transfer_write] = wayland.Write(memoryview(b"data"), float("inf"))
                raise UndoError("Initial offer failed")

            try:
                with patch.dict(os.environ, environment, clear=True), \
                     patch.object(wayland.socket, "socket", return_value=client), \
                     patch.object(Wayland, "send"), \
                     patch.object(Wayland, "sync", enter_registry), \
                     patch.object(Wayland, "_settle_initial_selection", fail_selection):
                    with self.assertRaisesRegex(UndoError, "Initial offer failed"):
                        Wayland()
                self.assertEqual(-1, client.fileno())
                for fd in (queued_write, transfer_write):
                    with self.assertRaises(OSError):
                        os.fstat(fd)
            finally:
                for fd in (queued_read, queued_write, transfer_read, transfer_write):
                    try:
                        os.close(fd)
                    except OSError:
                        pass

    def test_x11_failed_selection_setup_restores_previous_error_handler(self):
        for failure in ("chunk", "sync"):
            with self.subTest(failure=failure):
                library, fixes = Mock(), Mock()
                library.XSetErrorHandler.return_value = 42
                library.XOpenDisplay.return_value = 100
                library.XInternAtom.return_value = 200
                library.XCreateSimpleWindow.return_value = 300
                library.XMaxRequestSize.return_value = 64 if failure == "chunk" else 1024
                expected = "Transfergröße" if failure == "chunk" else "sync failure"
                with patch.object(ctypes.util, "find_library", side_effect=["xlib", "xfixes"]), \
                     patch.object(ctypes, "CDLL", side_effect=[library, fixes]), \
                     patch.object(X11, "sync", side_effect=UndoError("sync failure")):
                    with self.assertRaisesRegex(UndoError, expected):
                        X11()
                self.assertEqual([
                    call.XSetErrorHandler(x11._X_ERROR_HANDLER),
                    call.XDestroyWindow(100, 300),
                    call.XCloseDisplay(100),
                    call.XSetErrorHandler(42),
                ], [entry for entry in library.mock_calls if entry[0] in (
                    "XSetErrorHandler", "XDestroyWindow", "XCloseDisplay",
                )])
                self.assertEqual({}, X11._displays)

    def test_replace_sends_payload_without_appending_it_to_header(self):
        payload = b"converted content" * 2048
        connection = MagicMock()
        connection.__enter__.return_value = connection
        connection.recv.return_value = b'{"code": 0, "result": ""}\n'
        with tempfile.TemporaryDirectory() as directory:
            fd = os.open(directory, os.O_RDONLY)
            with patch.object(cli, "private_directory", return_value=(directory, fd)), \
                 patch.object(cli, "connect", return_value=connection), \
                 patch.object(sys, "stdin", Mock(buffer=Mock(read=Mock(return_value=payload)))):
                self.assertEqual("", cli.client(str(HELPER), "replace", "token"))
        sent_header, sent_payload = [entry.args[0] for entry in connection.sendall.call_args_list]
        length, = daemon.REQUEST_LENGTH.unpack_from(sent_header)
        request = sent_header[daemon.REQUEST_LENGTH.size:]
        self.assertEqual(length, len(request))
        self.assertEqual({"command": "replace", "token": "token", "size": len(payload)}, json.loads(request))
        self.assertIs(payload, sent_payload)


class NativeRepresentationTests(unittest.TestCase):
    def test_x11_32bit_words_use_native_long_slots(self):
        class Transport:
            def XChangeProperty(self, display, window, prop, typ, fmt, mode, ptr, count):
                self.format = fmt
                self.values = [ctypes.cast(ptr, ctypes.POINTER(x11.UL))[i] for i in range(count)]
        clip = X11.__new__(X11)
        clip.x, clip.display = Transport(), None
        raw = b"\x01\x00\x00\x00\xff\xff\xff\xff"
        if sys.byteorder != "little":
            raw = b"\x00\x00\x00\x01\xff\xff\xff\xff"
        clip.put(1, 2, 3, 32, raw)
        self.assertEqual(32, clip.x.format)
        self.assertEqual([1, 0xffffffff], clip.x.values)

    def test_xclip_incr_capability_is_not_a_payload_format(self):
        clip = X11.__new__(X11)
        clip.targets, clip.timestamp, clip.multiple, clip.incr = 1, 2, 3, 4
        clip.atom_type, clip.window = 11, 999
        names = {"SAVE_TARGETS": 6, "DELETE": 7, "INSERT_SELECTION": 8, "INSERT_PROPERTY": 9}
        clip.atom = lambda name: names[name]
        clip.stamp = lambda: X11Stamp(1, 42)
        requested = []
        def convert(target, deadline, limit):
            requested.append(target)
            if target == clip.targets:
                return X11Format(11, 32, struct.pack("=6I", 1, 2, 3, 4, 6, 10))
            return X11Format(12, 8, b"opaque\x00data")
        clip._convert = convert
        stamp, snapshot = clip.capture()
        self.assertEqual(X11Stamp(1, 42), stamp)
        self.assertEqual({10: X11Format(12, 8, b"opaque\x00data")}, snapshot)
        self.assertEqual([1, 10], requested)

    def test_dead_foreign_x11_window_does_not_poison_transfer(self):
        clip = X11.__new__(X11)
        clip.window, clip.read_window, clip.errors = 123, 456, False
        error = x11.XError(0, None, 789, 0, 3, 18, 0)
        clip._error(error)
        self.assertFalse(clip.errors)
        error.resourceid = clip.read_window
        clip._error(error)
        self.assertTrue(clip.errors)

    def test_wayland_fd_precedes_its_send_message_in_a_batch(self):
        sender, receiver = socket.socketpair()
        read_fd, write_fd = os.pipe()
        clip = Wayland.__new__(Wayland)
        clip.sock, clip.message, clip.fds = receiver, bytearray(), deque()
        clip.objects = {2: "callback", 10: "source"}
        clip.completed, clip.writes = set(), {}
        clip.sources = {10: {"binary": b"\x00\xffpayload"}}
        callback = struct.pack("=III", 2, 12 << 16, 0)
        body = wayland.pack_string("binary")
        message = struct.pack("=II", 10, (8 + len(body)) << 16) + body
        try:
            sender.sendmsg([callback + message], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                                  array.array("i", [write_fd]))])
            os.close(write_fd)
            write_fd = None
            clip._read(time.monotonic() + 1)
            self.assertEqual(1, len(clip.fds))
            clip._read(time.monotonic() + 1)
            self.assertFalse(clip.fds)
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
        clip = Wayland.__new__(Wayland)
        clip.objects = {10: "source"}
        clip.sources = {10: {"empty": b"", "binary": b"\x00\xffdata"}}
        clip.writes = {}
        for name, expected in clip.sources[10].items():
            read_fd, write_fd = os.pipe()
            fds = deque([write_fd])
            clip._event(10, 0, wayland.pack_string(name), fds)
            self.assertFalse(fds)
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
    if isinstance(clip, X11):
        result = {clip.atom(name): X11Format(clip.atom(name), 8, value) for name, value in data.items()}
        result[clip.atom("application/x-md-clip-16")] = X11Format(clip.atom("MD_CLIP_SHORT"), 16, b"\x00\x01\xff\xff\x20\x30")
        result[clip.atom("application/x-md-clip-32")] = X11Format(clip.atom("MD_CLIP_LONG"), 32, b"\x00\x00\x00\x01\xff\xff\xff\xff")
        return result
    return data


def source():
    clip = backends.backend()
    held = []
    delayed = False
    capture_marker = Path(os.environ["MD_CLIP_TEST_CAPTURE_MARKER"])
    if isinstance(clip, Wayland):
        original = clip._event
        def event(obj, opcode, data, fds):
            if delayed and clip.objects.get(obj) == "source" and opcode == 0:
                if fds:
                    held.append(fds.popleft())
                    capture_marker.touch()
            else:
                original(obj, opcode, data, fds)
        clip._event = event
    else:
        transfers = {}
        original_serve, original_put = clip._serve, clip.put
        def serve(requestor, target, prop):
            value = clip._value(target)
            if value and len(value.data) > clip.chunk:
                transfers[(requestor, prop)] = {"expected": len(value.data), "sent": 0, "chunks": 0,
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
            else:
                capture_marker.touch()
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
                if isinstance(clip, X11):
                    values = list(transfers.values())[-5:]
                    for stats in values:
                        stats["active"] = any(info.value.data and len(info.value.data) == stats["expected"] for info in clip.outgoing.values())
                    state = {"transfers": values, "errors": clip.errors,
                             "last_error": asdict(clip.last_error) if clip.last_error else None,
                             "active": [{"size": len(item.value.data), "position": item.sent,
                                         "remaining": round(item.expires - time.monotonic(), 3)}
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
        self.capture_directory = tempfile.TemporaryDirectory(prefix="md-clip-capture-test-")
        self.capture_marker = Path(self.capture_directory.name) / "started"
        self.publisher = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--source"],
                                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                          text=True, bufsize=1,
                                          env=dict(os.environ, MD_CLIP_TEST_CAPTURE_MARKER=str(self.capture_marker)))
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
            self.capture_directory.cleanup()

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
        clip = backends.backend()
        try:
            _, snapshot = clip.capture()
            return snapshot
        except UndoError as error:
            if isinstance(clip, X11) and self.publisher.poll() is None:
                self.source_command("stats")
                if select.select([self.publisher.stderr], [], [], 1)[0]:
                    stats = self.publisher.stderr.readline().strip()
                    raise UndoError(str(error) + " Sender: " + stats, error.code)
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
            shutil.copytree(
                HELPER.parent / "clipboard_undo", other.parent / "clipboard_undo",
                ignore=shutil.ignore_patterns("__pycache__"),
            )
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
        clip = backends.backend()
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

    def test_x11_selection_already_buffered_by_xlib(self):
        clip = backends.backend()
        try:
            if not isinstance(clip, X11):
                self.skipTest("Xlibs Ereigniswarteschlange betrifft nur X11")
            clip.x.XPutBackEvent.restype = ctypes.c_int
            clip.x.XPutBackEvent.argtypes = [x11.P, ctypes.POINTER(x11.Event)]
            pump = clip.pump
            buffered = []
            def queue_after_pump(*args):
                pump(*args)
                if not buffered and clip.selection_events:
                    # Eine echte Antwort in Xlibs Queue nachbilden, nachdem
                    # der letzte Pump-Durchlauf sie noch nicht übernehmen konnte.
                    event = x11.Event()
                    event.selection = clip.selection_events.pop(0)
                    clip.x.XPutBackEvent(clip.display, ctypes.byref(event))
                    clip.x.XSync(clip.display, 0)
                    buffered.append(event.selection.target)
            clip.pump = queue_after_pump
            _, snapshot = clip.capture()
            self.assertTrue(buffered)
            self.assertEqual(fixture(clip), snapshot)
        finally:
            clip.close()

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
        # Der Eigentümerwechsel muss während einer wirklich begonnenen
        # Materialisierung erfolgen, nicht während des Python-Prozessstarts.
        deadline = time.monotonic() + 5
        while not self.capture_marker.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(self.capture_marker.exists(), "Capture hat nicht begonnen")
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

    def test_doctor_reads_no_formats(self):
        self.source_command("delay")
        start = time.monotonic()
        result = subprocess.run([str(ROOT / "bin/md-clip"), "--doctor", "--json"],
                                capture_output=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr.decode())
        doc = json.loads(result.stdout)
        self.assertEqual({'status': 'ready', 'code': 'ok'}, doc['session'])
        self.assertTrue(doc['capabilities']['clipboard_replace'])
        self.assertLess(time.monotonic() - start, 3)
        self.source_command("republish")

    def test_status_preserves_real_pending_and_undo(self):
        token = self.run_helper("prepare")
        self.assertTrue(json.loads(self.run_helper("status", token))["pending_valid"])
        self.run_helper("replace", token, b"new")
        self.assertTrue(json.loads(self.run_helper("status"))["undo_available"])
        pending = self.run_helper("prepare")
        status = json.loads(self.run_helper("status", pending))
        self.assertTrue(status["undo_available"] and status["pending_valid"])
        self.run_helper("cancel", pending)
        self.run_helper("undo")
        self.assertFalse(json.loads(self.run_helper("status"))["undo_available"])

    def test_invalid_rtf_preserves_previous_real_undo(self):
        original = self.read_clipboard()
        self.run_helper("replace", self.run_helper("prepare"), b"previous")
        before = self.read_clipboard()
        result = subprocess.run([str(ROOT/"bin/md-clip"),"--stdin","--from","rtf","--replace","--quiet"],
                                input=b"plain tagged as RTF",capture_output=True,timeout=20)
        self.assertEqual(3,result.returncode,result.stderr.decode())
        self.assertEqual(b"",result.stdout)
        self.assertIn(b"RTF-Kopf",result.stderr)
        self.assertEqual(before,self.read_clipboard())
        self.run_helper("undo")
        self.assertEqual(original,self.read_clipboard())

    def test_parent_only_signal_with_open_stdin_preserves_real_undo(self):
        for interruption, expected in ((signal.SIGINT,130),(signal.SIGTERM,143)):
            with self.subTest(signal=interruption):
                original = self.read_clipboard()
                self.run_helper("replace", self.run_helper("prepare"), b"previous")
                before = self.read_clipboard()
                proc = subprocess.Popen([str(ROOT/"bin/md-clip"),"--stdin","--plain","--replace","--quiet"],
                                        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
                try:
                    end = time.monotonic()+8; child = None
                    while time.monotonic()<end and proc.poll() is None:
                        for value in Path('/proc/%s/task/%s/children'%(proc.pid,proc.pid)).read_text().split():
                            path = Path('/proc')/value/'comm'
                            try:
                                name = path.read_text().strip()
                            except FileNotFoundError:
                                continue  # The child may exit between listing and reading /proc.
                            if name == 'cat':
                                child = int(value)
                                break
                        if child is not None:break
                        time.sleep(.01)
                    self.assertIsNotNone(child, 'stdin-Kopie wurde nicht erreicht')
                    proc.send_signal(interruption)
                    self.assertEqual(expected,proc.wait(timeout=5))
                    out,error=proc.communicate(timeout=2)
                    self.assertEqual(b'',out,error.decode())
                    self.assertFalse(Path('/proc/%s'%child).exists(), 'stdin-Kindprozess blieb aktiv')
                    self.assertEqual(before,self.read_clipboard())
                    self.run_helper('cancel',self.run_helper('prepare'))
                    self.run_helper('undo')
                    self.assertEqual(original,self.read_clipboard())
                finally:
                    if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL)
                    proc.communicate(timeout=3)

    def test_diagnose_reads_no_formats(self):
        self.source_command("delay")
        start = time.monotonic()
        self.assertEqual("ok", self.run_helper("diagnose"))
        self.assertLess(time.monotonic() - start, 2)
        self.source_command("republish")

    def test_available_reads_no_formats(self):
        self.source_command("delay")
        start = time.monotonic()
        self.run_helper("available")
        self.assertLess(time.monotonic() - start, 2)
        self.source_command("republish")

    def test_only_socket_is_persisted(self):
        token = self.run_helper("prepare")
        self.run_helper("replace", token, b"sensitive-test-data")
        path, fd = daemon.private_directory()
        os.close(fd)
        self.assertEqual(["control.sock"], os.listdir(path))
        self.run_helper("undo")

    def test_bad_socket_request_preserves_saved_undo(self):
        original = self.read_clipboard()
        token = self.run_helper("prepare")
        self.run_helper("replace", token, b"new")
        path, fd = daemon.private_directory()
        os.close(fd)
        for request in (b"x", b"[]", b"null", b'{"command":[]}'):
            connection = daemon.connect(os.path.join(path, "control.sock"))
            with connection:
                connection.sendall(len(request).to_bytes(4, "big") + request)
                response = json.loads(connection.recv(1024))
                self.assertEqual(2, response["code"])
        self.run_helper("undo")
        self.assertEqual(original, self.read_clipboard())

    def unread_request(self, request, data=b''):
        path, fd = daemon.private_directory(); os.close(fd)
        connection = daemon.connect(os.path.join(path,'control.sock'))
        try:
            connection.shutdown(socket.SHUT_RD)
            payload=json.dumps(dict(request,size=len(data))).encode()
            connection.sendall(len(payload).to_bytes(4,'big')+payload+data)
            return connection
        except BaseException:
            connection.close();raise

    def test_failed_prepare_reply_releases_only_new_pending(self):
        original=self.read_clipboard()
        self.run_helper('replace',self.run_helper('prepare'),b'previous')
        before=self.read_clipboard()
        with self.unread_request({'command':'prepare'}):
            self.assertTrue(json.loads(self.run_helper('status'))['undo_available'])
            next_token=self.run_helper('prepare')
        self.assertEqual(before,self.read_clipboard())
        self.run_helper('cancel',next_token)
        self.run_helper('undo');self.assertEqual(original,self.read_clipboard())

    def test_unread_rejections_and_status_preserve_existing_pending(self):
        original=self.read_clipboard()
        self.run_helper('replace',self.run_helper('prepare'),b'previous')
        token=self.run_helper('prepare');before=self.read_clipboard()
        for request in ({'command':'prepare'}, {'command':[]}, {'command':'status','token':token}):
            with self.unread_request(request):
                status=json.loads(self.run_helper('status',token))
                self.assertTrue(status['pending_valid'] and status['undo_available'])
            self.assertEqual(before,self.read_clipboard())
        self.run_helper('cancel',token);self.run_helper('undo')
        self.assertEqual(original,self.read_clipboard())

    def test_unread_replace_reply_preserves_success_and_undo(self):
        original=self.read_clipboard();token=self.run_helper('prepare')
        with self.unread_request({'command':'replace','token':token},b'replacement'):
            status=json.loads(self.run_helper('status',token))
            self.assertTrue(status['undo_available'] and not status['pending_valid'])
        clip=backends.backend()
        try:self.assertEqual(clip.text(b'replacement'),self.read_clipboard())
        finally:clip.close()
        self.run_helper('undo');self.assertEqual(original,self.read_clipboard())

    def test_stop_preserves_external_owner(self):
        self.run_helper("prepare")
        self.run_helper("stop")
        self.assertTrue(self.read_clipboard())


if __name__ == "__main__":
    if "--source" in sys.argv:
        source()
    else:
        unittest.main(argv=[sys.argv[0]])
