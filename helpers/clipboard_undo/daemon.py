from __future__ import annotations

from contextlib import closing, ExitStack
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
import resource
import select
import socket
import stat
import struct
import time
from typing import Callable, Optional, Union

from .backends import backend
from .wayland import Wayland
from .common import (
    Clipboard, IO_CHUNK, MAX_BYTES, POLL_INTERVAL, READ_TIMEOUT, Snapshot, Stamp,
    TTL, UndoError,
)
from .state import State

REQUEST_LENGTH = struct.Struct("!I")
MAX_REQUEST_LENGTH = 1024
MAX_TOKEN_LENGTH = 128
PEER_CREDENTIALS = struct.Struct("3i")


@dataclass(frozen=True)
class Request:
    name: str
    token: str
    payload: bytes


def private_directory(create: bool = True) -> tuple[str, int]:
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    base = runtime if runtime else "/tmp"
    if runtime:
        st = os.lstat(runtime)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
            raise UndoError("XDG_RUNTIME_DIR ist kein privates Sitzungsverzeichnis.", 2)
    identity = "\0".join((os.environ.get("WAYLAND_DISPLAY", ""), os.environ.get("DISPLAY", ""),
                             os.environ.get("XDG_SESSION_ID", ""), runtime))
    key = hashlib.sha256(identity.encode()).hexdigest()[:20]
    path = os.path.join(base, "md-clip-undo-{}-{}".format(os.getuid(), key))
    if create:
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise UndoError("Clipboard-Undo-Verzeichnis ist nicht sicher.", 2)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    actual = os.fstat(fd)
    if (st.st_dev, st.st_ino) != (actual.st_dev, actual.st_ino):
        os.close(fd)
        raise UndoError("Clipboard-Undo-Verzeichnis wurde ausgetauscht.", 2)
    return path, fd


def check_socket(path: Union[str, os.PathLike[str]]) -> None:
    st = os.lstat(path)
    if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600:
        raise UndoError("Clipboard-Undo-Socket ist nicht sicher.", 2)


def check_peer(connection: socket.socket) -> None:
    credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, PEER_CREDENTIALS.size)
    _, uid, _ = PEER_CREDENTIALS.unpack(credentials)
    if uid != os.getuid():
        raise UndoError("Clipboard-Undo-Prozess gehört einem anderen Benutzer.", 2)


def read_exact(connection: socket.socket, count: int, deadline: float, pump: Callable[[], None]) -> bytes:
    parts = bytearray()
    while len(parts) < count:
        pump()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise UndoError("Clipboard-Undo-Anfrage überschreitet das Zeitlimit.", 2)
        if not select.select([connection], [], [], min(remaining, POLL_INTERVAL))[0]:
            continue
        data = connection.recv(min(IO_CHUNK, count - len(parts)))
        if not data:
            raise UndoError("Unvollständige Clipboard-Undo-Anfrage.", 2)
        parts.extend(data)
    return bytes(parts)


def read_request(connection: socket.socket, pump: Callable[[], None]) -> Request:
    check_peer(connection)
    deadline = time.monotonic() + READ_TIMEOUT
    length, = REQUEST_LENGTH.unpack(read_exact(connection, REQUEST_LENGTH.size, deadline, pump))
    if length > MAX_REQUEST_LENGTH:
        raise UndoError("Clipboard-Undo-Anfrage ist zu groß.", 2)
    request = json.loads(read_exact(connection, length, deadline, pump))
    if not isinstance(request, dict):
        raise UndoError("Ungültige Clipboard-Undo-Anfrage.", 2)
    size = request.get("size", 0)
    if not isinstance(size, int) or size < 0 or size > MAX_BYTES:
        raise UndoError("Clipboard-Undo-Ausgabe ist zu groß.", 3)
    data = read_exact(connection, size, deadline, pump)
    name, token = request.get("command", ""), request.get("token", "")
    if not isinstance(name, str) or not isinstance(token, str) or len(token) > MAX_TOKEN_LENGTH:
        raise UndoError("Ungültige Clipboard-Undo-Anfrage.", 2)
    return Request(name, token, data)


def remove_socket(path: str, inode: int) -> None:
    try:
        check_socket(path)
        if os.lstat(path).st_ino == inode:
            os.unlink(path)
    except FileNotFoundError:
        pass


def serve(path: str, directory_fd: int) -> None:
    with ExitStack() as cleanup:
        cleanup.callback(os.close, directory_fd)
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        try:
            fcntl.flock(directory_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        socket_path = os.path.join(path, "control.sock")
        try:
            check_socket(socket_path)
        except FileNotFoundError:
            pass
        else:
            os.unlink(socket_path)
        clipboard = cleanup.enter_context(closing(backend()))
        server = cleanup.enter_context(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM))
        previous_umask = os.umask(0o177)
        try:
            server.bind(socket_path)
        finally:
            os.umask(previous_umask)
        cleanup.callback(remove_socket, socket_path, os.lstat(socket_path).st_ino)
        os.chmod(socket_path, 0o600)
        server.listen(8)
        if isinstance(clipboard, Wayland):
            serve_requests(server, clipboard)
        else:
            serve_requests(server, clipboard)


def serve_requests(server: socket.socket, clipboard: Clipboard[Stamp, Snapshot]) -> None:
    state = State(clipboard)
    last_client = time.monotonic()
    running = True
    while running:
        clipboard.pump()
        state.expire()
        # Wiederhergestellte Formate müssen auch nach Verbrauch der Sicherung abrufbar bleiben.
        if not clipboard.owned and not state.pending and not state.saved and time.monotonic() - last_client > TTL:
            break
        if not select.select([server, clipboard.fileno()], clipboard.write_fds(), [], POLL_INTERVAL)[0]:
            continue
        if not select.select([server], [], [], 0)[0]:
            continue
        connection, _ = server.accept()
        with connection:
            connection.settimeout(READ_TIMEOUT)
            prepared_token: Optional[str] = None
            response: dict[str, Union[int, str]]
            try:
                request = read_request(connection, clipboard.pump)
                if request.name != "status":
                    last_client = time.monotonic()
                if request.name == "stop":
                    running, result = False, ""
                else:
                    result = state.command(request.name, request.token, request.payload)
                    if request.name == "prepare":
                        prepared_token = result
                response = {"code": 0, "result": result}
            except UndoError as error:
                response = {"code": error.code, "error": str(error)}
            except (ValueError, TypeError, OSError):
                response = {"code": 2, "error": "Ungültige Clipboard-Undo-Anfrage oder Verbindung."}
            try:
                connection.sendall(json.dumps(response).encode() + b"\n")
            except OSError:
                # Ohne übertragene Token-Antwort kann dieser Client nicht stornieren.
                if prepared_token is not None:
                    state.cancel(prepared_token)


def connect(socket_path: str) -> socket.socket:
    check_socket(socket_path)
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(READ_TIMEOUT)
        connection.connect(socket_path)
        check_peer(connection)
        return connection
    except BaseException:
        connection.close()
        raise
