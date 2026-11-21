from __future__ import annotations

import array
from collections import deque
from dataclasses import dataclass
import os
import select
import socket
import struct
import time
from typing import Dict, Optional

from .common import (
    IO_CHUNK, MAX_BYTES, MAX_TRANSFERS, MAX_TYPES, POLL_INTERVAL, READ_TIMEOUT,
    TOTAL_TIMEOUT, UndoError, deadline_wait,
)

DISPLAY_ID = 1
REGISTRY_ID = 2
FIRST_CLIENT_ID = 3
FIRST_SERVER_ID = 0xFF000000
MESSAGE_HEADER_SIZE = 8
MAX_FDS_PER_READ = 32
MAX_QUEUED_FDS = 64
SELECTION_QUIET_TIME = 0.1

DISPLAY_SYNC = 0
DISPLAY_GET_REGISTRY = 1
DISPLAY_ERROR = 0
REGISTRY_BIND = 0
REGISTRY_GLOBAL = 0
REGISTRY_GLOBAL_REMOVE = 1
CALLBACK_DONE = 0

EXT_MANAGER = "ext_data_control_manager_v1"
WLR_MANAGER = "zwlr_data_control_manager_v1"
SEAT_INTERFACE = "wl_seat"

# ext_data_control und zwlr_data_control verwenden hier dieselben Opcodes.
MANAGER_CREATE_SOURCE = 0
MANAGER_GET_DEVICE = 1
DEVICE_SET_SELECTION = 0
DEVICE_DATA_OFFER = 0
DEVICE_SELECTION = 1
DEVICE_FINISHED = 2
DEVICE_PRIMARY_SELECTION = 3
OFFER_RECEIVE = 0
OFFER_DESTROY = 1
OFFER_MIME_TYPE = 0
SOURCE_OFFER = 0
SOURCE_DESTROY = 1
SOURCE_SEND = 0
SOURCE_CANCELLED = 1


WaylandSnapshot = Dict[str, bytes]


@dataclass(frozen=True)
class Global:
    interface: str
    version: int


@dataclass
class Write:
    payload: memoryview
    expires: float


def pack_string(value: str) -> bytes:
    raw = value.encode("utf-8") + b"\0"
    return struct.pack("=I", len(raw)) + raw + b"\0" * (-len(raw) % 4)


def unpack_string(data: bytes) -> tuple[str, int]:
    if len(data) < 4:
        raise UndoError("Ungültige Wayland-Nachricht.", 2)
    size = struct.unpack_from("=I", data)[0]
    if not size or size > len(data) - 4 or data[3 + size] != 0:
        raise UndoError("Ungültiger Wayland-Formatname.", 2)
    try:
        value = data[4:3 + size].decode("utf-8")
        if "\0" in value:
            raise UndoError("Ungültiger Wayland-Formatname.", 2)
        return value, 4 + ((size + 3) & ~3)
    except UnicodeError:
        raise UndoError("Ungültiger Wayland-Formatname.", 2)


class Wayland:
    """Die vier Data-Control-Interfaces haben in ext/wlr dieselben Opcodes."""
    def __init__(self, probe: bool = False) -> None:
        display = os.environ.get("WAYLAND_DISPLAY", "")
        runtime = os.environ.get("XDG_RUNTIME_DIR", "")
        if not display or not runtime:
            raise UndoError("Wayland-Sitzung oder XDG_RUNTIME_DIR fehlt.", 2, "wayland-runtime-missing")
        self.objects = {DISPLAY_ID: "display", REGISTRY_ID: "registry"}
        self.next_id = FIRST_CLIENT_ID
        self.globals: dict[int, Global] = {}
        self.offers: dict[int, list[str]] = {}
        self.selection = 0
        self.primary = 0
        self.generation = 0
        self.sources: dict[int, WaylandSnapshot] = {}
        self.current_source = 0
        self.owned = False
        self.writes: dict[int, Write] = {}
        self.completed: set[int] = set()
        self.message = bytearray()
        self.fds: deque[int] = deque()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.settimeout(READ_TIMEOUT)
            try:
                self.sock.connect(os.path.join(runtime, display))
            except OSError as error:
                raise UndoError("Wayland-Verbindung nicht verfügbar.", 2, "wayland-connect-failed") from error
            self._initialize_registry(probe)
        except BaseException:
            self.close()
            raise

    def _initialize_registry(self, probe: bool) -> None:
        self.send(DISPLAY_ID, DISPLAY_GET_REGISTRY, struct.pack("=I", REGISTRY_ID))
        self.sync()
        managers = [
            (name, entry) for name, entry in self.globals.items()
            if entry.interface in (EXT_MANAGER, WLR_MANAGER)
        ]
        seats = [name for name, entry in self.globals.items() if entry.interface == SEAT_INTERFACE]
        if not managers:
            raise UndoError("Wayland-Undo benötigt Data-Control.", 2, "wayland-data-control-missing")
        if len(seats) != 1:
            raise UndoError("Wayland-Undo benötigt genau einen Seat.", 2, "wayland-seat-unsupported")
        if probe:
            return
        manager_name, manager = min(managers, key=lambda item: item[1].interface != EXT_MANAGER)
        version = min(manager.version, 1 if manager.interface == EXT_MANAGER else 2)
        self.manager = self.bind(manager_name, manager.interface, version, "manager")
        seat = self.bind(seats[0], SEAT_INTERFACE, 1, "seat")
        self.device = self.new_id("device")
        self.send(self.manager, MANAGER_GET_DEVICE, struct.pack("=II", self.device, seat))
        self.sync()
        self._settle_initial_selection()

    def _settle_initial_selection(self) -> None:
        deadline = time.monotonic() + READ_TIMEOUT
        observed, quiet_since = self.generation, time.monotonic()
        while time.monotonic() < deadline:
            self.pump(min(POLL_INTERVAL, max(0, deadline - time.monotonic())))
            if self.generation != observed:
                observed, quiet_since = self.generation, time.monotonic()
            if self.generation and time.monotonic() - quiet_since >= SELECTION_QUIET_TIME:
                self.sync()
                if self.generation == observed:
                    return
                observed, quiet_since = self.generation, time.monotonic()
        raise UndoError("Das erste Wayland-Clipboard-Angebot ist nicht stabil lesbar.")

    def fileno(self) -> int:
        return self.sock.fileno()

    def write_fds(self) -> list[int]:
        return list(self.writes)

    def new_id(self, kind: str) -> int:
        result = self.next_id
        self.next_id += 1
        if self.next_id >= FIRST_SERVER_ID:
            raise UndoError("Wayland-Objektgrenze erreicht.", 2)
        self.objects[result] = kind
        return result

    def send(self, obj: int, opcode: int, data: bytes = b"", fd: Optional[int] = None) -> None:
        wire = struct.pack("=II", obj, ((MESSAGE_HEADER_SIZE + len(data)) << 16) | opcode) + data
        try:
            if fd is None:
                self.sock.sendall(wire)
            else:
                sent = self.sock.sendmsg([wire], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])
                if sent < len(wire):
                    self.sock.sendall(wire[sent:])
        except OSError:
            raise UndoError("Wayland-Verbindung wurde beendet.", 2)

    def bind(self, name: int, iface: str, version: int, kind: str) -> int:
        obj = self.new_id(kind)
        payload = struct.pack("=I", name) + pack_string(iface) + struct.pack("=II", version, obj)
        self.send(REGISTRY_ID, REGISTRY_BIND, payload)
        return obj

    def _read(self, deadline: float) -> None:
        # Eine Nachricht wird vollständig gelesen; FDs laufen in eigener Protokollreihenfolge.
        while len(self.message) < MESSAGE_HEADER_SIZE:
            deadline_wait(self.sock, deadline)
            self._recv(MESSAGE_HEADER_SIZE - len(self.message))
        obj, header = struct.unpack_from("=II", self.message)
        size, opcode = header >> 16, header & 0xffff
        if size < MESSAGE_HEADER_SIZE or size % 4:
            raise UndoError("Ungültige Wayland-Nachricht.", 2)
        while len(self.message) < size:
            deadline_wait(self.sock, deadline)
            self._recv(size - len(self.message))
        data = bytes(self.message[MESSAGE_HEADER_SIZE:])
        self.message.clear()
        # Wayland bündelt Nachrichten: SCM_RIGHTS gehört zur FD-Reihenfolge, nicht zum Header.
        self._event(obj, opcode, data, self.fds)

    def _recv(self, size: int) -> None:
        try:
            fd_space = socket.CMSG_SPACE(MAX_FDS_PER_READ * array.array("i").itemsize)
            data, ancillary, flags, _ = self.sock.recvmsg(size, fd_space)
        except OSError:
            raise UndoError("Wayland-Verbindung wurde beendet.", 2)
        for level, kind, payload in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                received = array.array("i")
                received.frombytes(payload[:len(payload) - len(payload) % received.itemsize])
                self.fds.extend(received)
        if not data or flags & socket.MSG_CTRUNC or len(self.fds) > MAX_QUEUED_FDS:
            raise UndoError("Unvollständige Wayland-Nachricht.", 2)
        self.message.extend(data)

    def _drop_offer(self, obj: int) -> None:
        if obj:
            self.send(obj, OFFER_DESTROY)
            self.offers.pop(obj, None)
            self.objects.pop(obj, None)

    def _event(self, obj: int, opcode: int, data: bytes, fds: deque[int]) -> None:
        kind = self.objects.get(obj)
        if kind == "display":
            if opcode == DISPLAY_ERROR:
                raise UndoError("Wayland lehnt Data-Control ab.", 2)
            return
        if kind == "registry":
            if opcode == REGISTRY_GLOBAL:
                name = struct.unpack_from("=I", data)[0]
                iface, end = unpack_string(data[4:])
                version = struct.unpack_from("=I", data, 4 + end)[0]
                self.globals[name] = Global(iface, version)
            elif opcode == REGISTRY_GLOBAL_REMOVE:
                name = struct.unpack_from("=I", data)[0]
                removed = self.globals.pop(name, None)
                if removed and removed.interface in (SEAT_INTERFACE, EXT_MANAGER, WLR_MANAGER):
                    raise UndoError("Wayland-Sitzung wurde geändert.", 2)
        elif kind == "callback" and opcode == CALLBACK_DONE:
            self.completed.add(obj)
            self.objects.pop(obj, None)
        elif kind == "device":
            if opcode == DEVICE_DATA_OFFER:
                offer = struct.unpack_from("=I", data)[0]
                self.objects[offer] = "offer"
                self.offers[offer] = []
            elif opcode == DEVICE_SELECTION:
                previous = self.selection
                self.selection = struct.unpack_from("=I", data)[0]
                self.generation += 1
                self._drop_offer(previous)
            elif opcode == DEVICE_FINISHED:
                raise UndoError("Wayland Data-Control wurde beendet.", 2)
            elif opcode == DEVICE_PRIMARY_SELECTION:
                self._drop_offer(self.primary)
                self.primary = struct.unpack_from("=I", data)[0]
        elif kind == "offer" and opcode == OFFER_MIME_TYPE:
            name, _ = unpack_string(data)
            # Ein zusätzliches Format zeigt capture an, dass das Angebot zu groß ist.
            names = self.offers[obj]
            if len(names) <= MAX_TYPES and name not in names:
                names.append(name)
        elif kind == "source":
            if opcode == SOURCE_SEND:
                name, _ = unpack_string(data)
                if not fds:
                    raise UndoError("Ungültiger Wayland-Datentransfer.", 2)
                fd = fds.popleft()
                payload = self.sources.get(obj, {}).get(name)
                if payload is None or len(self.writes) >= MAX_TRANSFERS:
                    os.close(fd)
                else:
                    try:
                        os.set_blocking(fd, False)
                        self.writes[fd] = Write(memoryview(payload), time.monotonic() + READ_TIMEOUT)
                    except BaseException:
                        os.close(fd)
                        raise
            elif opcode == SOURCE_CANCELLED:
                if obj == self.current_source:
                    self.owned = False
                    self.current_source = 0
                    self.generation += 1
                self.sources.pop(obj, None)
                self.send(obj, SOURCE_DESTROY)
                self.objects.pop(obj, None)

    def _pump_writes(self) -> None:
        now = time.monotonic()
        ready = select.select([], list(self.writes), [], 0)[1] if self.writes else []
        for fd, transfer in list(self.writes.items()):
            done = now >= transfer.expires
            if fd in ready and not done:
                try:
                    count = os.write(fd, transfer.payload[:IO_CHUNK])
                    transfer.payload = transfer.payload[count:]
                    done = not transfer.payload
                except BlockingIOError:
                    pass
                except OSError:
                    done = True
            if done:
                os.close(fd)
                del self.writes[fd]

    def pump(self, timeout: float = 0) -> None:
        self._pump_writes()
        deadline = time.monotonic() + max(timeout, POLL_INTERVAL)
        if select.select([self.sock], self.write_fds(), [], timeout)[0]:
            self._read(deadline)
            while select.select([self.sock], [], [], 0)[0]:
                self._read(deadline)
        self._pump_writes()

    def sync(self) -> None:
        obj = self.new_id("callback")
        self.send(DISPLAY_ID, DISPLAY_SYNC, struct.pack("=I", obj))
        deadline = time.monotonic() + READ_TIMEOUT
        while obj not in self.completed:
            self._pump_writes()
            self._read(deadline)
        self.completed.remove(obj)

    def stamp(self) -> int:
        self.sync()
        return self.generation

    def capture(self) -> tuple[int, WaylandSnapshot]:
        stamp = self.stamp()
        offer = self.selection
        names = list(self.offers.get(offer, []))
        if len(names) > MAX_TYPES or (offer and not names):
            raise UndoError("Clipboard-Formatangebot ist unvollständig oder zu groß.")
        result, total = {}, 0
        deadline = time.monotonic() + TOTAL_TIMEOUT
        for name in names:
            if self.generation != stamp:
                raise UndoError("Clipboard wurde während der Sicherung geändert.")
            read_fd, write_fd = os.pipe()
            parts = []
            item_deadline = min(deadline, time.monotonic() + READ_TIMEOUT)
            try:
                try:
                    os.set_blocking(read_fd, False)
                    self.send(offer, OFFER_RECEIVE, pack_string(name), write_fd)
                finally:
                    os.close(write_fd)
                while True:
                    remaining = item_deadline - time.monotonic()
                    if remaining <= 0:
                        raise UndoError("Clipboard-Format antwortet nicht rechtzeitig.")
                    ready = select.select(
                        [read_fd, self.sock], self.write_fds(), [], min(remaining, POLL_INTERVAL),
                    )[0]
                    if self.sock in ready:
                        self._read(item_deadline)
                    self._pump_writes()
                    if self.generation != stamp:
                        raise UndoError("Clipboard wurde während der Sicherung geändert.")
                    if read_fd in ready:
                        part = os.read(read_fd, IO_CHUNK)
                        if not part:
                            break
                        total += len(part)
                        if total > MAX_BYTES:
                            raise UndoError("Clipboard überschreitet die Sicherungsgrenze von 64 MiB.")
                        parts.append(part)
            finally:
                os.close(read_fd)
            result[name] = b"".join(parts)
        if self.stamp() != stamp:
            raise UndoError("Clipboard wurde während der Sicherung geändert.")
        return stamp, result

    def text(self, data: bytes) -> WaylandSnapshot:
        return {"text/plain;charset=utf-8": data, "text/plain": data}

    def publish(self, data: WaylandSnapshot) -> int:
        if data:
            obj = self.new_id("source")
            self.sources[obj] = data
            self.send(self.manager, MANAGER_CREATE_SOURCE, struct.pack("=I", obj))
            for name in data:
                self.send(obj, SOURCE_OFFER, pack_string(name))
        else:
            obj = 0
        self.current_source = obj
        self.owned = bool(obj)
        self.send(self.device, DEVICE_SET_SELECTION, struct.pack("=I", obj))
        self.sync()
        if data and (not self.owned or self.current_source != obj):
            raise UndoError("Clipboard-Schreiben wurde abgewiesen.", 3)
        return self.generation

    def close(self) -> None:
        self.sock.close()
        for fd in self.writes:
            os.close(fd)
        self.writes.clear()
        while self.fds:
            os.close(self.fds.popleft())
