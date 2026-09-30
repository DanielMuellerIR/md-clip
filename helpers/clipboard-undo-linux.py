#!/usr/bin/env python3
"""Einmaliges vollständiges Clipboard-Undo; Nutzdaten bleiben im Daemon-RAM."""
import array
import ctypes as C
import ctypes.util
import fcntl
import hashlib
import json
import os
import resource
import secrets
import select
import socket
import stat
import struct
import subprocess
import sys
import time

MAX_BYTES = 64 * 1024 * 1024
MAX_TYPES = 128
TTL = 600
READ_TIMEOUT = 5
TOTAL_TIMEOUT = 30


class UndoError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def deadline_wait(fd, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
        raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")


def pack_string(value):
    raw = value.encode("utf-8") + b"\0"
    return struct.pack("=I", len(raw)) + raw + b"\0" * (-len(raw) % 4)


def unpack_string(data):
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
    def __init__(self, probe=False):
        display = os.environ.get("WAYLAND_DISPLAY", "")
        runtime = os.environ.get("XDG_RUNTIME_DIR", "")
        if not display or not runtime:
            raise UndoError("Wayland-Sitzung oder XDG_RUNTIME_DIR fehlt.", 2)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(READ_TIMEOUT)
        try:
            self.sock.connect(display if os.path.isabs(display) else os.path.join(runtime, display))
        except OSError:
            self.sock.close()
            raise UndoError("Wayland-Verbindung nicht verfügbar.", 2)
        self.objects = {1: "display", 2: "registry"}
        self.next_id = 3
        self.globals = {}
        self.offers = {}
        self.selection = 0
        self.primary = 0
        self.generation = 0
        self.sources = {}
        self.current_source = 0
        self.owned = False
        self.writes = {}
        self.completed = set()
        self.message = bytearray()
        self.fds = []
        self.send(1, 1, struct.pack("=I", 2))
        self.sync()
        managers = [(name, iface, version) for name, (iface, version) in self.globals.items()
                    if iface in ("ext_data_control_manager_v1", "zwlr_data_control_manager_v1")]
        seats = [name for name, (iface, _) in self.globals.items() if iface == "wl_seat"]
        if not managers or len(seats) != 1:
            self.close()
            raise UndoError("Wayland-Undo benötigt Data-Control und genau einen Seat.", 2)
        managers.sort(key=lambda entry: entry[1] != "ext_data_control_manager_v1")
        if probe:
            return
        name, iface, version = managers[0]
        self.manager = self.bind(name, iface, min(version, 1 if iface.startswith("ext_") else 2), "manager")
        seat = self.bind(seats[0], "wl_seat", 1, "seat")
        self.device = self.new_id("device")
        self.send(self.manager, 1, struct.pack("=II", self.device, seat))
        self.sync()
        self._settle_initial_selection()

    def _settle_initial_selection(self):
        deadline = time.monotonic() + READ_TIMEOUT
        observed, quiet_since = self.generation, time.monotonic()
        while time.monotonic() < deadline:
            self.pump(min(.05, max(0, deadline - time.monotonic())))
            if self.generation != observed:
                observed, quiet_since = self.generation, time.monotonic()
            if self.generation and time.monotonic() - quiet_since >= .1:
                self.sync()
                if self.generation == observed:
                    return
                observed, quiet_since = self.generation, time.monotonic()
        raise UndoError("Das erste Wayland-Clipboard-Angebot ist nicht stabil lesbar.")

    def fileno(self):
        return self.sock.fileno()

    def new_id(self, kind):
        result = self.next_id
        self.next_id += 1
        if self.next_id >= 0xff000000:
            raise UndoError("Wayland-Objektgrenze erreicht.", 2)
        self.objects[result] = kind
        return result

    def send(self, obj, opcode, data=b"", fd=None):
        wire = struct.pack("=II", obj, ((8 + len(data)) << 16) | opcode) + data
        try:
            if fd is None:
                self.sock.sendall(wire)
            else:
                sent = self.sock.sendmsg([wire], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])
                if sent < len(wire):
                    self.sock.sendall(wire[sent:])
        except OSError:
            raise UndoError("Wayland-Verbindung wurde beendet.", 2)

    def bind(self, name, iface, version, kind):
        obj = self.new_id(kind)
        self.send(2, 0, struct.pack("=I", name) + pack_string(iface) + struct.pack("=II", version, obj))
        return obj

    def _read(self, deadline):
        # Eine Nachricht wird vollständig gelesen; FDs laufen in eigener Protokollreihenfolge.
        while len(self.message) < 8:
            deadline_wait(self.sock, deadline)
            self._recv(8 - len(self.message))
        obj, header = struct.unpack_from("=II", self.message)
        size, opcode = header >> 16, header & 0xffff
        if size < 8 or size % 4:
            raise UndoError("Ungültige Wayland-Nachricht.", 2)
        while len(self.message) < size:
            deadline_wait(self.sock, deadline)
            self._recv(size - len(self.message))
        data = bytes(self.message[8:])
        self.message.clear()
        # Wayland bündelt Nachrichten: SCM_RIGHTS gehört zur FD-Reihenfolge, nicht zum Header.
        self._event(obj, opcode, data, self.fds)

    def _recv(self, size):
        try:
            data, ancillary, flags, _ = self.sock.recvmsg(size, socket.CMSG_SPACE(32 * array.array("i").itemsize))
        except OSError:
            raise UndoError("Wayland-Verbindung wurde beendet.", 2)
        for level, kind, payload in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                received = array.array("i")
                received.frombytes(payload[:len(payload) - len(payload) % received.itemsize])
                self.fds.extend(received)
        if not data or flags & socket.MSG_CTRUNC or len(self.fds) > 64:
            raise UndoError("Unvollständige Wayland-Nachricht.", 2)
        self.message.extend(data)

    def _drop_offer(self, obj):
        if obj:
            self.send(obj, 1)
            self.offers.pop(obj, None)
            self.objects.pop(obj, None)

    def _event(self, obj, opcode, data, fds):
        kind = self.objects.get(obj)
        if kind == "display":
            if opcode == 0:
                raise UndoError("Wayland lehnt Data-Control ab.", 2)
            return
        if kind == "registry":
            if opcode == 0:
                name = struct.unpack_from("=I", data)[0]
                iface, end = unpack_string(data[4:])
                version = struct.unpack_from("=I", data, 4 + end)[0]
                self.globals[name] = (iface, version)
            elif opcode == 1:
                name = struct.unpack_from("=I", data)[0]
                previous = self.globals.pop(name, ("", 0))[0]
                if previous in ("wl_seat", "ext_data_control_manager_v1", "zwlr_data_control_manager_v1"):
                    raise UndoError("Wayland-Sitzung wurde geändert.", 2)
        elif kind == "callback":
            self.completed.add(obj)
            self.objects.pop(obj, None)
        elif kind == "device":
            if opcode == 0:
                offer = struct.unpack_from("=I", data)[0]
                self.objects[offer] = "offer"
                self.offers[offer] = []
            elif opcode == 1:
                previous = self.selection
                self.selection = struct.unpack_from("=I", data)[0]
                self.generation += 1
                self._drop_offer(previous)
            elif opcode == 2:
                raise UndoError("Wayland Data-Control wurde beendet.", 2)
            elif opcode == 3:
                self._drop_offer(self.primary)
                self.primary = struct.unpack_from("=I", data)[0]
        elif kind == "offer":
            name, _ = unpack_string(data)
            if name not in self.offers[obj]:
                self.offers[obj].append(name)
            if len(self.offers[obj]) > MAX_TYPES:
                # Primär-Auswahl ist außerhalb unseres Vertrags; Clipboard wird bei capture geprüft.
                self.offers[obj] = self.offers[obj][:MAX_TYPES + 1]
        elif kind == "source":
            if opcode == 0:
                name, _ = unpack_string(data)
                if not fds:
                    raise UndoError("Ungültiger Wayland-Datentransfer.", 2)
                fd = fds.pop(0)
                payload = self.sources.get(obj, {}).get(name)
                if payload is None or len(self.writes) >= 32:
                    os.close(fd)
                else:
                    os.set_blocking(fd, False)
                    self.writes[fd] = [memoryview(payload), time.monotonic() + READ_TIMEOUT]
            elif opcode == 1:
                if obj == self.current_source:
                    self.owned = False
                    self.current_source = 0
                    self.generation += 1
                self.sources.pop(obj, None)
                self.send(obj, 1)
                self.objects.pop(obj, None)

    def _pump_writes(self):
        now = time.monotonic()
        ready = select.select([], list(self.writes), [], 0)[1] if self.writes else []
        for fd, (payload, expires) in list(self.writes.items()):
            done = now >= expires
            if fd in ready and not done:
                try:
                    count = os.write(fd, payload[:65536])
                    payload = payload[count:]
                    self.writes[fd][0] = payload
                    done = not payload
                except BlockingIOError:
                    pass
                except OSError:
                    done = True
            if done:
                os.close(fd)
                del self.writes[fd]

    def pump(self, timeout=0):
        self._pump_writes()
        deadline = time.monotonic() + max(timeout, .05)
        if select.select([self.sock], list(self.writes), [], timeout)[0]:
            self._read(deadline)
            while select.select([self.sock], [], [], 0)[0]:
                self._read(deadline)
        self._pump_writes()

    def sync(self):
        obj = self.new_id("callback")
        self.send(1, 0, struct.pack("=I", obj))
        deadline = time.monotonic() + READ_TIMEOUT
        while obj not in self.completed:
            self._pump_writes()
            self._read(deadline)
        self.completed.remove(obj)

    def stamp(self):
        self.sync()
        return self.generation

    def capture(self):
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
            os.set_blocking(read_fd, False)
            try:
                self.send(offer, 0, pack_string(name), write_fd)
            finally:
                os.close(write_fd)
            parts = []
            item_deadline = min(deadline, time.monotonic() + READ_TIMEOUT)
            try:
                while True:
                    remaining = item_deadline - time.monotonic()
                    if remaining <= 0:
                        raise UndoError("Clipboard-Format antwortet nicht rechtzeitig.")
                    ready = select.select([read_fd, self.sock], list(self.writes), [], min(remaining, .05))[0]
                    if self.sock in ready:
                        self._read(item_deadline)
                    self._pump_writes()
                    if self.generation != stamp:
                        raise UndoError("Clipboard wurde während der Sicherung geändert.")
                    if read_fd in ready:
                        part = os.read(read_fd, 65536)
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

    def text(self, data):
        return {"text/plain;charset=utf-8": data, "text/plain": data}

    def publish(self, data):
        if data:
            obj = self.new_id("source")
            self.sources[obj] = data
            self.send(self.manager, 0, struct.pack("=I", obj))
            for name in data:
                self.send(obj, 0, pack_string(name))
        else:
            obj = 0
        self.current_source = obj
        self.owned = bool(obj)
        self.send(self.device, 0, struct.pack("=I", obj))
        self.sync()
        if data and (not self.owned or self.current_source != obj):
            raise UndoError("Clipboard-Schreiben wurde abgewiesen.", 3)
        return self.generation

    def close(self):
        for fd in getattr(self, "writes", {}):
            os.close(fd)
        for fd in getattr(self, "fds", []):
            os.close(fd)
        self.sock.close()


UL = C.c_ulong
P = C.c_void_p


class Selection(C.Structure):
    _fields_ = [("type", C.c_int), ("serial", UL), ("send_event", C.c_int), ("display", P),
                ("requestor", UL), ("selection", UL), ("target", UL), ("property", UL), ("time", UL)]


class Request(C.Structure):
    _fields_ = [("type", C.c_int), ("serial", UL), ("send_event", C.c_int), ("display", P),
                ("owner", UL), ("requestor", UL), ("selection", UL), ("target", UL), ("property", UL), ("time", UL)]


class Property(C.Structure):
    _fields_ = [("type", C.c_int), ("serial", UL), ("send_event", C.c_int), ("display", P),
                ("window", UL), ("atom", UL), ("time", UL), ("state", C.c_int)]


class Fixes(C.Structure):
    _fields_ = [("type", C.c_int), ("serial", UL), ("send_event", C.c_int), ("display", P),
                ("window", UL), ("subtype", C.c_int), ("owner", UL), ("selection", UL),
                ("timestamp", UL), ("selection_timestamp", UL)]


class XError(C.Structure):
    _fields_ = [("type", C.c_int), ("display", P), ("resourceid", UL), ("serial", UL),
                ("error_code", C.c_ubyte), ("request_code", C.c_ubyte), ("minor_code", C.c_ubyte)]


class Event(C.Union):
    _fields_ = [("type", C.c_int), ("selection", Selection), ("request", Request),
                ("property", Property), ("fixes", Fixes), ("pad", C.c_long * 24)]


class X11:
    def __init__(self, probe=False):
        xname, fname = C.util.find_library("X11"), C.util.find_library("Xfixes")
        if not xname or not fname:
            raise UndoError("X11-Undo benötigt libX11 und libXfixes.", 2)
        self.x, self.f = C.CDLL(xname), C.CDLL(fname)
        signatures = {
            "XOpenDisplay": (P, [C.c_char_p]), "XCloseDisplay": (C.c_int, [P]),
            "XDefaultRootWindow": (UL, [P]), "XConnectionNumber": (C.c_int, [P]),
            "XCreateSimpleWindow": (UL, [P, UL, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_uint, UL, UL]),
            "XDestroyWindow": (C.c_int, [P, UL]), "XInternAtom": (UL, [P, C.c_char_p, C.c_int]),
            "XGetSelectionOwner": (UL, [P, UL]), "XSetSelectionOwner": (C.c_int, [P, UL, UL, UL]),
            "XConvertSelection": (C.c_int, [P, UL, UL, UL, UL, UL]),
            "XSelectInput": (C.c_int, [P, UL, C.c_long]), "XPending": (C.c_int, [P]),
            "XNextEvent": (C.c_int, [P, C.POINTER(Event)]), "XFlush": (C.c_int, [P]),
            "XSync": (C.c_int, [P, C.c_int]), "XFree": (C.c_int, [P]),
            "XDeleteProperty": (C.c_int, [P, UL, UL]),
            "XGetWindowProperty": (C.c_int, [P, UL, UL, C.c_long, C.c_long, C.c_int, UL,
                                            C.POINTER(UL), C.POINTER(C.c_int), C.POINTER(UL), C.POINTER(UL), C.POINTER(P)]),
            "XChangeProperty": (C.c_int, [P, UL, UL, UL, C.c_int, C.c_int, P, C.c_int]),
            "XSendEvent": (C.c_int, [P, UL, C.c_int, C.c_long, C.POINTER(Event)]),
            "XMaxRequestSize": (C.c_long, [P]), "XSetErrorHandler": (P, [P]),
        }
        for name, (result, args) in signatures.items():
            fun = getattr(self.x, name)
            fun.restype, fun.argtypes = result, args
        self.f.XFixesQueryExtension.argtypes = [P, C.POINTER(C.c_int), C.POINTER(C.c_int)]
        self.f.XFixesQueryExtension.restype = C.c_int
        self.f.XFixesSelectSelectionInput.argtypes = [P, UL, UL, UL]
        self.errors = False
        self.error_handler = C.CFUNCTYPE(C.c_int, P, P)(self._error)
        self.previous_handler = self.x.XSetErrorHandler(self.error_handler)
        self.display = self.x.XOpenDisplay(None)
        if not self.display:
            self.x.XSetErrorHandler(self.previous_handler)
            raise UndoError("X11-Verbindung nicht verfügbar.", 2)
        event, error = C.c_int(), C.c_int()
        if not self.f.XFixesQueryExtension(self.display, C.byref(event), C.byref(error)):
            self.close()
            raise UndoError("X11-Server unterstützt XFixes nicht.", 2)
        self.fix_event = event.value
        self.window = 0
        self.read_window = 0
        self.generation = 0
        self.owner_time = 0
        self.owned = False
        self.data = {}
        self.outgoing = {}
        self.selection_events = []
        self.property_events = []
        if probe:
            return
        self.clipboard = self.atom("CLIPBOARD")
        self.targets = self.atom("TARGETS")
        self.timestamp = self.atom("TIMESTAMP")
        self.multiple = self.atom("MULTIPLE")
        self.incr = self.atom("INCR")
        self.atom_type = self.atom("ATOM")
        self.integer = self.atom("INTEGER")
        self.atom_pair = self.atom("ATOM_PAIR")
        self.property_atom = self.atom("_MD_CLIP_UNDO_DATA")
        self.window = self.x.XCreateSimpleWindow(self.display, self.x.XDefaultRootWindow(self.display), 0, 0, 1, 1, 0, 0, 0)
        self.x.XSelectInput(self.display, self.window, 1 << 22)
        self.f.XFixesSelectSelectionInput(self.display, self.window, self.clipboard, 7)
        self.chunk = min(65536, (self.x.XMaxRequestSize(self.display) - 64) * 4)
        if self.chunk <= 0:
            raise UndoError("X11-Transfergröße ist unbrauchbar.", 2)
        self.sync()

    def _error(self, display, error):
        details = C.cast(error, C.POINTER(XError)).contents
        own_windows = (getattr(self, "window", 0), getattr(self, "read_window", 0))
        self.last_error = (details.error_code, details.request_code, details.minor_code,
                           details.resourceid, *own_windows)
        # Geschlossene Empfänger liefern noch späte BadWindow-Fehler früherer Transfers.
        if details.error_code == 3 and details.resourceid not in own_windows:
            return 0
        self.errors = True
        return 0

    def atom(self, name):
        return self.x.XInternAtom(self.display, name.encode(), 0)

    def fileno(self):
        return self.x.XConnectionNumber(self.display)

    def sync(self):
        self.x.XSync(self.display, 0)
        self.pump()
        if self.errors:
            self.errors = False
            raise UndoError("X11-Clipboard-Anfrage wurde abgewiesen.")

    def stamp(self):
        self.sync()
        owner = self.x.XGetSelectionOwner(self.display, self.clipboard)
        self.sync()
        self.owned = owner == self.window
        return self.generation, owner

    def pump(self, timeout=0):
        if timeout and not self.x.XPending(self.display):
            select.select([self.fileno()], [], [], timeout)
        while self.x.XPending(self.display):
            event = Event()
            self.x.XNextEvent(self.display, C.byref(event))
            if event.type == self.fix_event:
                self.generation += 1
                self.owned = event.fixes.owner == self.window
                self.owner_time = event.fixes.selection_timestamp
                if not self.owned:
                    self.data = {}
                    self.outgoing.clear()
            elif event.type == 30:
                previous_errors = self.errors
                self.errors = False
                self._request(event.request)
                self.x.XSync(self.display, 0)
                # Ein verschwundener fremder Empfänger darf unser Angebot nicht beenden.
                self.errors = previous_errors
            elif event.type == 31 and event.selection.requestor == self.read_window:
                self.selection_events.append(Selection.from_buffer_copy(event.selection))
            elif event.type == 28:
                prop = event.property
                key = (prop.window, prop.atom)
                if prop.state == 1 and key in self.outgoing:
                    typ, fmt, data, pos, expires = self.outgoing[key]
                    chunk = data[pos:pos + self.chunk]
                    previous_errors = self.errors
                    self.errors = False
                    self.put(prop.window, prop.atom, typ, fmt, chunk)
                    self.x.XSync(self.display, 0)
                    failed = self.errors
                    self.errors = previous_errors
                    if chunk and not failed:
                        self.outgoing[key] = typ, fmt, data, pos + len(chunk), expires
                    else:
                        del self.outgoing[key]
                elif prop.window == self.read_window and prop.atom == self.property_atom and prop.state == 0:
                    self.property_events.append(True)
        now = time.monotonic()
        for key, transfer in list(self.outgoing.items()):
            if transfer[4] <= now:
                del self.outgoing[key]
        self.x.XFlush(self.display)

    def get(self, window, prop, delete=False, limit=MAX_BYTES):
        typ, fmt, count, after, ptr = UL(), C.c_int(), UL(), UL(), P()
        status = self.x.XGetWindowProperty(self.display, window, prop, 0, (limit + 3) // 4,
                                          int(delete), 0, C.byref(typ), C.byref(fmt), C.byref(count), C.byref(after), C.byref(ptr))
        try:
            if status or after.value or fmt.value not in (8, 16, 32) or count.value * (fmt.value // 8) > limit:
                raise UndoError("X11-Format ist nicht vollständig lesbar oder zu groß.")
            if fmt.value == 32:
                words = C.cast(ptr, C.POINTER(UL))
                data = array.array("I", (words[index] & 0xffffffff for index in range(count.value))).tobytes()
            else:
                data = C.string_at(ptr, count.value * (fmt.value // 8))
            return typ.value, fmt.value, data
        finally:
            if ptr:
                self.x.XFree(ptr)

    def property_ready(self, window, prop):
        typ, fmt, count, after, ptr = UL(), C.c_int(), UL(), UL(), P()
        status = self.x.XGetWindowProperty(self.display, window, prop, 0, 0, 0, 0,
                                          C.byref(typ), C.byref(fmt), C.byref(count), C.byref(after), C.byref(ptr))
        if ptr:
            self.x.XFree(ptr)
        if status:
            raise UndoError("X11-Transferfenster ist nicht mehr verfügbar.")
        return bool(typ.value)

    def put(self, window, prop, typ, fmt, data):
        if fmt == 32:
            values = array.array("I")
            values.frombytes(data)
            native_words = array.array("L", values)
            payload = (UL * len(values)).from_buffer(native_words)
        else:
            payload = C.create_string_buffer(data)
        self.x.XChangeProperty(self.display, window, prop, typ, fmt, 0, C.cast(payload, P), len(data) // (fmt // 8))

    def _convert(self, target, deadline, limit):
        # Eigene Requestor-Fenster verhindern verspätete Antworten in der nächsten Sicherung.
        self.read_window = self.x.XCreateSimpleWindow(self.display, self.x.XDefaultRootWindow(self.display),
                                                     0, 0, 1, 1, 0, 0, 0)
        self.x.XSelectInput(self.display, self.read_window, 1 << 22)
        self.read_phase = "Formatantwort"
        try:
            return self._convert_property(target, deadline, limit)
        except UndoError as error:
            raise UndoError("{} (X11-Typ {}, {}).".format(str(error).rstrip("."), target, self.read_phase), error.code)
        finally:
            self.x.XDestroyWindow(self.display, self.read_window)
            self.read_window = 0
            self.selection_events.clear()
            self.property_events.clear()
            self.x.XFlush(self.display)

    def _convert_property(self, target, deadline, limit):
        if time.monotonic() >= deadline:
            raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")
        self.selection_events.clear()
        self.property_events.clear()
        self.x.XDeleteProperty(self.display, self.read_window, self.property_atom)
        self.x.XConvertSelection(self.display, self.clipboard, target, self.property_atom, self.read_window, 0)
        self.x.XFlush(self.display)
        while not self.selection_events:
            self.pump()
            if not self.selection_events:
                deadline_wait(self.fileno(), deadline)
        event = self.selection_events.pop(0)
        if event.target != target or not event.property:
            raise UndoError("Ein angebotenes X11-Format ist nicht lesbar.")
        typ, fmt, data = self.get(self.read_window, self.property_atom, False, limit)
        if typ != self.incr:
            self.x.XDeleteProperty(self.display, self.read_window, self.property_atom)
            if time.monotonic() >= deadline:
                raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")
            return typ, fmt, data
        # xclip kündigt INCR ohne Längenwort an; die Stream-Grenze bleibt strikt.
        if fmt != 32 or len(data) not in (0, 4):
            raise UndoError("X11-INCR-Ankündigung ist ungültig (Format {}, {} Bytes).".format(fmt, len(data)))
        if data and struct.unpack("=I", data)[0] > limit:
            raise UndoError("X11-INCR überschreitet die Sicherungsgrenze ({} > {} Bytes).".format(
                struct.unpack("=I", data)[0], limit))
        self.property_events.clear()
        self.x.XDeleteProperty(self.display, self.read_window, self.property_atom)
        self.x.XFlush(self.display)
        parts, total, result_type, result_fmt = [], 0, None, None
        self.read_phase = "INCR-Daten"
        while True:
            while True:
                self.pump()
                self.property_events.clear()
                # INCR-Daten sind die Property; Hinweise können mit synchronen Antworten einlaufen.
                if self.property_ready(self.read_window, self.property_atom):
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")
                select.select([self.fileno()], [], [], min(remaining, .05))
            typ, fmt, chunk = self.get(self.read_window, self.property_atom, True, limit - total)
            if result_type is None:
                result_type, result_fmt = typ, fmt
            if typ != result_type or fmt != result_fmt:
                raise UndoError("X11-INCR änderte sein Datenformat.")
            if time.monotonic() >= deadline:
                raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")
            if not chunk:
                return result_type, result_fmt, b"".join(parts)
            total += len(chunk)
            self.read_phase = "INCR-Daten, {} Bytes gelesen".format(total)
            parts.append(chunk)
            self.x.XFlush(self.display)

    def capture(self):
        stamp = self.stamp()
        if not stamp[1]:
            return stamp, {}
        if stamp[1] == self.window:
            if len(self.data) > MAX_TYPES or sum(len(item[2]) for item in self.data.values()) > MAX_BYTES:
                raise UndoError("Clipboard überschreitet die Sicherungsgrenze von 64 MiB.")
            return stamp, dict(self.data)
        start = time.monotonic()
        typ, fmt, raw = self._convert(self.targets, start + READ_TIMEOUT, (MAX_TYPES + 16) * 4)
        if typ != self.atom_type or fmt != 32 or len(raw) % 4:
            raise UndoError("X11-TARGETS ist nicht vollständig lesbar.")
        targets = list(dict.fromkeys(struct.unpack("=" + "I" * (len(raw) // 4), raw)))
        protocol = {self.targets, self.timestamp, self.multiple, self.incr, self.atom("SAVE_TARGETS")}
        forbidden = {self.atom(name) for name in ("DELETE", "INSERT_SELECTION", "INSERT_PROPERTY")}
        if forbidden.intersection(targets) or len(targets) > MAX_TYPES + len(protocol):
            raise UndoError("X11-Clipboard bietet nicht sicher wiederherstellbare Formate an.")
        targets = [target for target in targets if target not in protocol]
        if len(targets) > MAX_TYPES or not targets or 0 in targets:
            raise UndoError("X11-Clipboard-Formatangebot ist unvollständig oder zu groß.")
        result, total = {}, 0
        for target in targets:
            if self.stamp() != stamp:
                raise UndoError("Clipboard wurde während der Sicherung geändert.")
            item = self._convert(target, min(start + TOTAL_TIMEOUT, time.monotonic() + READ_TIMEOUT), MAX_BYTES - total)
            total += len(item[2])
            result[target] = item
        if self.stamp() != stamp:
            raise UndoError("Clipboard wurde während der Sicherung geändert.")
        return stamp, result

    def _value(self, target):
        if target == self.targets:
            atoms = list(self.data) + [self.targets, self.timestamp, self.multiple]
            return self.atom_type, 32, struct.pack("=" + "I" * len(atoms), *atoms)
        if target == self.timestamp:
            return self.integer, 32, struct.pack("=I", self.owner_time & 0xffffffff)
        return self.data.get(target)

    def _serve(self, requestor, target, prop):
        item = self._value(target)
        if not item or not prop:
            return False
        typ, fmt, data = item
        if len(data) > self.chunk:
            if len(self.outgoing) >= 32 or (requestor, prop) in self.outgoing:
                return False
            self.x.XSelectInput(self.display, requestor, 1 << 22)
            self.outgoing[(requestor, prop)] = typ, fmt, data, 0, time.monotonic() + READ_TIMEOUT
            self.put(requestor, prop, self.incr, 32, struct.pack("=I", len(data)))
        else:
            self.put(requestor, prop, typ, fmt, data)
        return True

    def _request(self, request):
        prop = request.property or request.target
        ok = self.owned and request.selection == self.clipboard
        if ok and request.target == self.multiple:
            try:
                typ, fmt, raw = self.get(request.requestor, prop, False, MAX_TYPES * 8)
                if typ != self.atom_pair or fmt != 32 or len(raw) % 8:
                    raise UndoError("Ungültige X11-MULTIPLE-Anfrage.")
                pairs = list(struct.unpack("=" + "I" * (len(raw) // 4), raw))
                for index in range(0, len(pairs), 2):
                    if pairs[index] == self.multiple or not self._serve(request.requestor, pairs[index], pairs[index + 1]):
                        pairs[index + 1] = 0
                self.put(request.requestor, prop, typ, fmt, struct.pack("=" + "I" * len(pairs), *pairs))
            except UndoError:
                ok = False
        elif ok:
            ok = self._serve(request.requestor, request.target, prop)
        event = Event()
        event.selection = Selection(31, 0, 1, self.display, request.requestor, request.selection,
                                    request.target, prop if ok else 0, request.time)
        self.x.XSendEvent(self.display, request.requestor, 0, 0, C.byref(event))

    def text(self, data):
        names = ("UTF8_STRING", "text/plain;charset=utf-8", "text/plain")
        return {self.atom(name): (self.atom(name), 8, data) for name in names}

    def publish(self, data):
        self.data = data
        self.x.XSetSelectionOwner(self.display, self.clipboard, self.window if data else 0, 0)
        self.sync()
        stamp = self.stamp()
        if data and stamp[1] != self.window:
            self.data = {}
            raise UndoError("Clipboard-Schreiben wurde abgewiesen.", 3)
        return stamp

    def close(self):
        if getattr(self, "window", 0):
            self.x.XDestroyWindow(self.display, self.window)
        if getattr(self, "display", None):
            self.x.XCloseDisplay(self.display)
        self.x.XSetErrorHandler(self.previous_handler)


def dependencies():
    if sys.platform != "linux" or sys.version_info < (3, 8):
        raise UndoError("Clipboard-Undo benötigt Linux und Python 3.8 oder neuer.", 2)
    if not hasattr(socket, "SO_PEERCRED") or not hasattr(os, "O_NOFOLLOW"):
        raise UndoError("Sichere lokale Clipboard-Undo-Verbindungen werden nicht unterstützt.", 2)
    if not os.environ.get("WAYLAND_DISPLAY"):
        try:
            for name in ("X11", "Xfixes"):
                library = C.util.find_library(name)
                if not library:
                    raise OSError()
                C.CDLL(library)
        except OSError:
            raise UndoError("X11-Undo benötigt libX11 und libXfixes.", 2)


def backend(probe=False):
    if sys.platform != "linux":
        raise UndoError("Dieser Clipboard-Helfer benötigt Linux.", 2)
    return Wayland(probe) if os.environ.get("WAYLAND_DISPLAY") else X11(probe)


class State:
    def __init__(self, clipboard, clock=time.monotonic):
        self.clipboard, self.clock = clipboard, clock
        self.pending = None
        self.saved = None

    def expire(self):
        now = self.clock()
        stamp = self.clipboard.stamp()
        if self.pending and (now >= self.pending[3] or stamp != self.pending[1]):
            self.pending = None
        if self.saved and (now >= self.saved[2] or stamp != self.saved[0]):
            self.saved = None

    def command(self, name, token="", data=b""):
        self.expire()
        if name == "prepare":
            if self.pending:
                raise UndoError("Eine Clipboard-Konvertierung ist bereits vorbereitet.")
            stamp, snapshot = self.clipboard.capture()
            token = secrets.token_hex(32)
            self.pending = token, stamp, snapshot, self.clock() + TTL
            return token
        if name == "cancel":
            if self.pending and secrets.compare_digest(token, self.pending[0]):
                self.pending = None
            return ""
        if name == "replace":
            if not self.pending or not secrets.compare_digest(token, self.pending[0]):
                raise UndoError("Clipboard-Sicherung fehlt oder ist abgelaufen.")
            pending, self.pending = self.pending, None
            if self.clipboard.stamp() != pending[1]:
                raise UndoError("Clipboard wurde seit der Sicherung geändert.")
            try:
                data.decode("utf-8")
            except UnicodeError:
                raise UndoError("Die Markdown-Ausgabe ist kein UTF-8-Text.", 3)
            if len(data) > MAX_BYTES:
                raise UndoError("Markdown-Ausgabe überschreitet 64 MiB.", 3)
            stamp = self.clipboard.publish(self.clipboard.text(data))
            self.saved = stamp, pending[2], self.clock() + TTL
            return ""
        if name == "undo":
            if not self.saved:
                raise UndoError("Kein gültiges Clipboard-Undo verfügbar.")
            saved, self.saved = self.saved, None
            if self.clipboard.stamp() != saved[0]:
                raise UndoError("Clipboard wurde nach der Konvertierung geändert.")
            self.clipboard.publish(saved[1])
            return ""
        raise UndoError("Unbekannter Clipboard-Undo-Aufruf.", 2)


def private_directory():
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


def check_socket(path):
    st = os.lstat(path)
    if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600:
        raise UndoError("Clipboard-Undo-Socket ist nicht sicher.", 2)


def check_peer(connection):
    _, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
    if uid != os.getuid():
        raise UndoError("Clipboard-Undo-Prozess gehört einem anderen Benutzer.", 2)


def read_exact(connection, count, deadline, clipboard=None):
    parts = bytearray()
    while len(parts) < count:
        if clipboard:
            clipboard.pump()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise UndoError("Clipboard-Undo-Anfrage überschreitet das Zeitlimit.", 2)
        if not select.select([connection], [], [], min(remaining, .05))[0]:
            continue
        data = connection.recv(min(65536, count - len(parts)))
        if not data:
            raise UndoError("Unvollständige Clipboard-Undo-Anfrage.", 2)
        parts.extend(data)
    return bytes(parts)


def serve(path, directory_fd):
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
    clipboard = backend()
    state = State(clipboard)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    os.umask(0o177)
    server.bind(socket_path)
    os.chmod(socket_path, 0o600)
    server.listen(8)
    socket_inode = os.lstat(socket_path).st_ino
    last_client = time.monotonic()
    running = True
    try:
        while running:
            clipboard.pump()
            state.expire()
            if not clipboard.owned and not state.pending and not state.saved and time.monotonic() - last_client > TTL:
                break
            writers = list(getattr(clipboard, "writes", {}))
            if not select.select([server, clipboard.fileno()], writers, [], .05)[0] or not select.select([server], [], [], 0)[0]:
                continue
            connection, _ = server.accept()
            last_client = time.monotonic()
            with connection:
                connection.settimeout(READ_TIMEOUT)
                try:
                    check_peer(connection)
                    expires = time.monotonic() + READ_TIMEOUT
                    length = struct.unpack("!I", read_exact(connection, 4, expires, clipboard))[0]
                    if length > 1024:
                        raise UndoError("Clipboard-Undo-Anfrage ist zu groß.", 2)
                    request = json.loads(read_exact(connection, length, expires, clipboard))
                    if not isinstance(request, dict):
                        raise UndoError("Ungültige Clipboard-Undo-Anfrage.", 2)
                    size = request.get("size", 0)
                    if not isinstance(size, int) or size < 0 or size > MAX_BYTES:
                        raise UndoError("Clipboard-Undo-Ausgabe ist zu groß.", 3)
                    data = read_exact(connection, size, expires, clipboard)
                    name, token = request.get("command", ""), request.get("token", "")
                    if not isinstance(name, str) or not isinstance(token, str) or len(token) > 128:
                        raise UndoError("Ungültige Clipboard-Undo-Anfrage.", 2)
                    if name == "stop":
                        running, result = False, ""
                    else:
                        result = state.command(name, token, data)
                    response = {"code": 0, "result": result}
                except UndoError as error:
                    response = {"code": error.code, "error": str(error)}
                except (ValueError, TypeError, OSError):
                    response = {"code": 2, "error": "Ungültige Clipboard-Undo-Anfrage oder Verbindung."}
                try:
                    connection.sendall(json.dumps(response).encode() + b"\n")
                except OSError:
                    pass
    finally:
        state.pending = state.saved = None
        clipboard.close()
        server.close()
        try:
            check_socket(socket_path)
            if os.lstat(socket_path).st_ino == socket_inode:
                os.unlink(socket_path)
        except FileNotFoundError:
            pass
        os.close(directory_fd)


def connect(socket_path):
    check_socket(socket_path)
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(READ_TIMEOUT)
    try:
        connection.connect(socket_path)
        check_peer(connection)
        return connection
    except BaseException:
        connection.close()
        raise


def client(command, token=""):
    if command == "dependencies":
        dependencies()
        return ""
    if command == "available":
        clipboard = backend(probe=True)
        clipboard.close()
        return ""
    path, directory_fd = private_directory()
    socket_path = os.path.join(path, "control.sock")
    if command == "__daemon":
        serve(path, directory_fd)
        return ""
    os.close(directory_fd)
    try:
        connection = connect(socket_path)
    except (FileNotFoundError, ConnectionRefusedError):
        if command != "prepare":
            if command in ("cancel", "stop"):
                return ""
            raise UndoError("Kein gültiges Clipboard-Undo verfügbar.")
        process = subprocess.Popen([sys.executable, os.path.realpath(__file__), "__daemon"],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   close_fds=True, start_new_session=True)
        deadline = time.monotonic() + READ_TIMEOUT
        while True:
            try:
                connection = connect(socket_path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.monotonic() >= deadline:
                    if process.poll() is None:
                        process.terminate()
                    raise UndoError("Clipboard-Undo-Dienst konnte nicht gestartet werden.", 2)
                time.sleep(.02)
    with connection:
        data = sys.stdin.buffer.read(MAX_BYTES + 1) if command == "replace" else b""
        if len(data) > MAX_BYTES:
            raise UndoError("Markdown-Ausgabe überschreitet 64 MiB.", 3)
        request = json.dumps({"command": command, "token": token, "size": len(data)}).encode()
        connection.settimeout(TOTAL_TIMEOUT + READ_TIMEOUT + 2)
        connection.sendall(struct.pack("!I", len(request)) + request + data)
        response = bytearray()
        while b"\n" not in response:
            part = connection.recv(1024)
            if not part or len(response) + len(part) > 4096:
                raise UndoError("Clipboard-Undo-Dienst hat keine gültige Antwort geliefert.", 2)
            response.extend(part)
        result = json.loads(response)
        if result["code"]:
            raise UndoError(result["error"], result["code"])
        return result["result"]


def main():
    try:
        if len(sys.argv) < 2 or sys.argv[1] not in ("dependencies", "available", "prepare", "replace", "cancel", "undo", "stop", "__daemon"):
            raise UndoError("Aufruf: clipboard-undo-linux.py dependencies|available|prepare|replace TOKEN|cancel TOKEN|undo", 2)
        command = sys.argv[1]
        if len(sys.argv) != (3 if command in ("replace", "cancel") else 2):
            raise UndoError("Ungültiger Clipboard-Undo-Aufruf.", 2)
        result = client(command, sys.argv[2] if len(sys.argv) == 3 else "")
        if result:
            print(result)
    except UndoError as error:
        print(str(error), file=sys.stderr)
        return error.code
    except (OSError, ValueError, KeyError, struct.error):
        print("Clipboard-Undo-Dienst oder Sitzungsverbindung nicht verfügbar.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
