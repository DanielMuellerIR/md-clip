from __future__ import annotations

import array
import ctypes as C
import ctypes.util
from dataclasses import dataclass
import select
import struct
import time
from typing import ClassVar, Dict, Optional

from .common import (
    IO_CHUNK, MAX_BYTES, MAX_TRANSFERS, MAX_TYPES, POLL_INTERVAL, READ_TIMEOUT,
    TOTAL_TIMEOUT, UndoError, deadline_wait,
)

UL = C.c_ulong
P = C.c_void_p
ErrorHandler = C.CFUNCTYPE(C.c_int, P, P)

BAD_WINDOW = 3
PROPERTY_NOTIFY = 28
SELECTION_REQUEST = 30
SELECTION_NOTIFY = 31
PROPERTY_DELETE = 1
PROPERTY_CHANGE_MASK = 1 << 22
XFIXES_SET_SELECTION_OWNER_NOTIFY_MASK = 1 << 0
XFIXES_SELECTION_WINDOW_DESTROY_NOTIFY_MASK = 1 << 1
XFIXES_SELECTION_CLIENT_CLOSE_NOTIFY_MASK = 1 << 2
XFIXES_SELECTION_NOTIFY_MASK = (
    XFIXES_SET_SELECTION_OWNER_NOTIFY_MASK
    | XFIXES_SELECTION_WINDOW_DESTROY_NOTIFY_MASK
    | XFIXES_SELECTION_CLIENT_CLOSE_NOTIFY_MASK
)

CURRENT_TIME = 0
ANY_PROPERTY_TYPE = 0
PROP_MODE_REPLACE = 0
REQUEST_RESERVE_WORDS = 64
WIRE_WORD_MASK = 0xFFFFFFFF


@dataclass(frozen=True)
class X11Format:
    atom: int
    bits: int
    data: bytes


@dataclass(frozen=True)
class X11Stamp:
    generation: int
    owner: int


@dataclass
class Transfer:
    value: X11Format
    expires: float
    sent: int = 0


@dataclass(frozen=True)
class ErrorDetails:
    error_code: int
    request_code: int
    minor_code: int
    resource_id: int
    owner_window: int
    read_window: int


X11Snapshot = Dict[int, X11Format]


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
    _displays: ClassVar[dict[int, X11]] = {}
    _previous_handler: ClassVar[Optional[int]] = None

    def __init__(self, probe: bool = False) -> None:
        xname, fname = C.util.find_library("X11"), C.util.find_library("Xfixes")
        if not xname or not fname:
            raise UndoError("X11-Undo benötigt libX11 und libXfixes.", 2, "x11-libraries-missing")
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
        self.last_error: Optional[ErrorDetails] = None
        self.window = 0
        self.read_window = 0
        self.generation = 0
        self.owner_time = 0
        self.owned = False
        self.data: X11Snapshot = {}
        self.outgoing: dict[tuple[int, int], Transfer] = {}
        self.selection_events: list[Selection] = []
        self.display: int = self.x.XOpenDisplay(None)
        if not self.display:
            raise UndoError("X11-Verbindung nicht verfügbar.", 2, "x11-connect-failed")

        try:
            if not X11._displays:
                X11._previous_handler = self.x.XSetErrorHandler(_X_ERROR_HANDLER)
            X11._displays[self.display] = self
            event, error = C.c_int(), C.c_int()
            if not self.f.XFixesQueryExtension(self.display, C.byref(event), C.byref(error)):
                raise UndoError("X11-Server unterstützt XFixes nicht.", 2, "x11-xfixes-missing")
            self.fix_event = event.value
            if not probe:
                self._initialize_selection()
        except BaseException:
            self.close()
            raise

    def _initialize_selection(self) -> None:
        self.clipboard = self.atom("CLIPBOARD")
        self.targets = self.atom("TARGETS")
        self.timestamp = self.atom("TIMESTAMP")
        self.multiple = self.atom("MULTIPLE")
        self.incr = self.atom("INCR")
        self.atom_type = self.atom("ATOM")
        self.integer = self.atom("INTEGER")
        self.atom_pair = self.atom("ATOM_PAIR")
        self.property_atom = self.atom("_MD_CLIP_UNDO_DATA")
        self.window = self._requestor_window()
        self.f.XFixesSelectSelectionInput(self.display, self.window, self.clipboard, XFIXES_SELECTION_NOTIFY_MASK)
        self.chunk = min(IO_CHUNK, (self.x.XMaxRequestSize(self.display) - REQUEST_RESERVE_WORDS) * 4)
        if self.chunk <= 0:
            raise UndoError("X11-Transfergröße ist unbrauchbar.", 2)
        self.sync()

    def _requestor_window(self) -> int:
        root = self.x.XDefaultRootWindow(self.display)
        window: int = self.x.XCreateSimpleWindow(self.display, root, 0, 0, 1, 1, 0, 0, 0)
        self.x.XSelectInput(self.display, window, PROPERTY_CHANGE_MASK)
        return window

    def _error(self, details: XError) -> None:
        own_windows = (self.window, self.read_window)
        self.last_error = ErrorDetails(
            details.error_code, details.request_code, details.minor_code,
            details.resourceid, self.window, self.read_window,
        )
        # Geschlossene Empfänger liefern noch späte BadWindow-Fehler früherer Transfers.
        if details.error_code != BAD_WINDOW or details.resourceid in own_windows:
            self.errors = True

    def atom(self, name: str) -> int:
        return int(self.x.XInternAtom(self.display, name.encode(), 0))

    def fileno(self) -> int:
        return int(self.x.XConnectionNumber(self.display))

    def write_fds(self) -> list[int]:
        return []

    def sync(self) -> None:
        self.x.XSync(self.display, 0)
        self.pump()
        if self.errors:
            self.errors = False
            raise UndoError("X11-Clipboard-Anfrage wurde abgewiesen.")

    def stamp(self) -> X11Stamp:
        self.sync()
        owner = self.x.XGetSelectionOwner(self.display, self.clipboard)
        self.sync()
        self.owned = owner == self.window
        return X11Stamp(self.generation, owner)

    def pump(self, timeout: float = 0) -> None:
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
            elif event.type == SELECTION_REQUEST:
                previous_errors = self.errors
                self.errors = False
                self._request(event.request)
                self.x.XSync(self.display, 0)
                # Ein verschwundener fremder Empfänger darf unser Angebot nicht beenden.
                self.errors = previous_errors
            elif event.type == SELECTION_NOTIFY and event.selection.requestor == self.read_window:
                self.selection_events.append(Selection.from_buffer_copy(event.selection))
            elif event.type == PROPERTY_NOTIFY:
                prop = event.property
                key = (prop.window, prop.atom)
                transfer = self.outgoing.get(key)
                if prop.state == PROPERTY_DELETE and transfer is not None:
                    value = transfer.value
                    chunk = value.data[transfer.sent:transfer.sent + self.chunk]
                    previous_errors = self.errors
                    self.errors = False
                    self.put(prop.window, prop.atom, value.atom, value.bits, chunk)
                    self.x.XSync(self.display, 0)
                    failed = self.errors
                    self.errors = previous_errors
                    if chunk and not failed:
                        transfer.sent += len(chunk)
                    else:
                        del self.outgoing[key]
        now = time.monotonic()
        for key, transfer in list(self.outgoing.items()):
            if transfer.expires <= now:
                del self.outgoing[key]
        self.x.XFlush(self.display)

    def get(self, window: int, prop: int, delete: bool = False, limit: int = MAX_BYTES) -> X11Format:
        typ, fmt, count, after, ptr = UL(), C.c_int(), UL(), UL(), P()
        status = self.x.XGetWindowProperty(self.display, window, prop, 0, (limit + 3) // 4,
                                          int(delete), ANY_PROPERTY_TYPE, C.byref(typ), C.byref(fmt), C.byref(count), C.byref(after), C.byref(ptr))
        try:
            if status or after.value or fmt.value not in (8, 16, 32) or count.value * (fmt.value // 8) > limit:
                raise UndoError("X11-Format ist nicht vollständig lesbar oder zu groß.")
            if fmt.value == 32:
                words = C.cast(ptr, C.POINTER(UL))
                data = array.array("I", (words[index] & WIRE_WORD_MASK for index in range(count.value))).tobytes()
            else:
                data = C.string_at(ptr, count.value * (fmt.value // 8))
            return X11Format(typ.value, fmt.value, data)
        finally:
            if ptr:
                self.x.XFree(ptr)

    def property_ready(self, window: int, prop: int) -> bool:
        typ, fmt, count, after, ptr = UL(), C.c_int(), UL(), UL(), P()
        status = self.x.XGetWindowProperty(self.display, window, prop, 0, 0, 0, ANY_PROPERTY_TYPE,
                                          C.byref(typ), C.byref(fmt), C.byref(count), C.byref(after), C.byref(ptr))
        if ptr:
            self.x.XFree(ptr)
        if status:
            raise UndoError("X11-Transferfenster ist nicht mehr verfügbar.")
        return bool(typ.value)

    def put(self, window: int, prop: int, typ: int, fmt: int, data: bytes) -> None:
        if fmt == 32:
            values = array.array("I")
            values.frombytes(data)
            native_words = array.array("L", values)
            payload: C.Array[UL] | C.Array[C.c_char]
            payload = (UL * len(values)).from_buffer(native_words)
        else:
            payload = C.create_string_buffer(data)
        self.x.XChangeProperty(self.display, window, prop, typ, fmt, PROP_MODE_REPLACE, C.cast(payload, P), len(data) // (fmt // 8))

    def _convert(self, target: int, deadline: float, limit: int) -> X11Format:
        # Eigene Requestor-Fenster verhindern verspätete Antworten in der nächsten Sicherung.
        self.read_window = self._requestor_window()
        self.read_phase = "Formatantwort"
        try:
            return self._convert_property(target, deadline, limit)
        except UndoError as error:
            raise UndoError("{} (X11-Typ {}, {}).".format(str(error).rstrip("."), target, self.read_phase), error.code)
        finally:
            self.x.XDestroyWindow(self.display, self.read_window)
            self.read_window = 0
            self.selection_events.clear()
            self.x.XFlush(self.display)

    def _convert_property(self, target: int, deadline: float, limit: int) -> X11Format:
        if time.monotonic() >= deadline:
            raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")
        self.selection_events.clear()
        self.x.XDeleteProperty(self.display, self.read_window, self.property_atom)
        self.x.XConvertSelection(self.display, self.clipboard, target, self.property_atom, self.read_window, CURRENT_TIME)
        self.x.XFlush(self.display)
        while not self.selection_events:
            if time.monotonic() >= deadline:
                raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")
            self.pump()
            # XFlush am Ende von pump kann Antworten bereits in Xlib puffern.
            # Dann ist der Socket leer, obwohl die nächste Antwort bereitliegt.
            if not self.selection_events and not self.x.XPending(self.display):
                deadline_wait(self.fileno(), deadline)
        event = self.selection_events.pop(0)
        if event.target != target or not event.property:
            raise UndoError("Ein angebotenes X11-Format ist nicht lesbar.")
        value = self.get(self.read_window, self.property_atom, limit=limit)
        if value.atom != self.incr:
            self.x.XDeleteProperty(self.display, self.read_window, self.property_atom)
            if time.monotonic() >= deadline:
                raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")
            return value
        # xclip kündigt INCR ohne Längenwort an; die Stream-Grenze bleibt strikt.
        if value.bits != 32 or len(value.data) not in (0, 4):
            raise UndoError("X11-INCR-Ankündigung ist ungültig (Format {}, {} Bytes).".format(value.bits, len(value.data)))
        announced = struct.unpack("=I", value.data)[0] if value.data else 0
        if announced > limit:
            raise UndoError(f"X11-INCR überschreitet die Sicherungsgrenze ({announced} > {limit} Bytes).")
        self.x.XDeleteProperty(self.display, self.read_window, self.property_atom)
        self.x.XFlush(self.display)
        parts: list[bytes] = []
        total, result_type, result_fmt = 0, None, None
        self.read_phase = "INCR-Daten"
        while True:
            while True:
                self.pump()
                # INCR-Daten sind die Property; Hinweise können mit synchronen Antworten einlaufen.
                if self.property_ready(self.read_window, self.property_atom):
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")
                select.select([self.fileno()], [], [], min(remaining, POLL_INTERVAL))
            chunk = self.get(self.read_window, self.property_atom, delete=True, limit=limit - total)
            if result_type is None:
                result_type, result_fmt = chunk.atom, chunk.bits
            if (chunk.atom, chunk.bits) != (result_type, result_fmt):
                raise UndoError("X11-INCR änderte sein Datenformat.")
            if time.monotonic() >= deadline:
                raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")
            if not chunk.data:
                return X11Format(chunk.atom, chunk.bits, b"".join(parts))
            total += len(chunk.data)
            self.read_phase = "INCR-Daten, {} Bytes gelesen".format(total)
            parts.append(chunk.data)
            self.x.XFlush(self.display)

    def capture(self) -> tuple[X11Stamp, X11Snapshot]:
        stamp = self.stamp()
        if not stamp.owner:
            return stamp, {}
        if stamp.owner == self.window:
            if len(self.data) > MAX_TYPES or sum(len(value.data) for value in self.data.values()) > MAX_BYTES:
                raise UndoError("Clipboard überschreitet die Sicherungsgrenze von 64 MiB.")
            return stamp, dict(self.data)
        start = time.monotonic()
        value = self._convert(self.targets, start + READ_TIMEOUT, (MAX_TYPES + 16) * 4)
        if value.atom != self.atom_type or value.bits != 32 or len(value.data) % 4:
            raise UndoError("X11-TARGETS ist nicht vollständig lesbar.")
        targets = list(dict.fromkeys(unpack_words(value.data)))
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
            deadline = min(start + TOTAL_TIMEOUT, time.monotonic() + READ_TIMEOUT)
            value = self._convert(target, deadline, MAX_BYTES - total)
            total += len(value.data)
            result[target] = value
        if self.stamp() != stamp:
            raise UndoError("Clipboard wurde während der Sicherung geändert.")
        return stamp, result

    def _value(self, target: int) -> Optional[X11Format]:
        if target == self.targets:
            atoms = list(self.data) + [self.targets, self.timestamp, self.multiple]
            return X11Format(self.atom_type, 32, struct.pack(f"={len(atoms)}I", *atoms))
        if target == self.timestamp:
            return X11Format(self.integer, 32, struct.pack("=I", self.owner_time & WIRE_WORD_MASK))
        return self.data.get(target)

    def _serve(self, requestor: int, target: int, prop: int) -> bool:
        value = self._value(target)
        if value is None or not prop:
            return False
        if len(value.data) > self.chunk:
            key = (requestor, prop)
            if len(self.outgoing) >= MAX_TRANSFERS or key in self.outgoing:
                return False
            self.x.XSelectInput(self.display, requestor, PROPERTY_CHANGE_MASK)
            self.outgoing[key] = Transfer(value, time.monotonic() + READ_TIMEOUT)
            self.put(requestor, prop, self.incr, 32, struct.pack("=I", len(value.data)))
        else:
            self.put(requestor, prop, value.atom, value.bits, value.data)
        return True

    def _request(self, request: Request) -> None:
        prop = request.property or request.target
        ok = self.owned and request.selection == self.clipboard
        if ok and request.target == self.multiple:
            try:
                value = self.get(request.requestor, prop, limit=MAX_TYPES * 8)
                if value.atom != self.atom_pair or value.bits != 32 or len(value.data) % 8:
                    raise UndoError("Ungültige X11-MULTIPLE-Anfrage.")
                pairs = list(unpack_words(value.data))
                for index in range(0, len(pairs), 2):
                    target, destination = pairs[index:index + 2]
                    if target == self.multiple or not self._serve(request.requestor, target, destination):
                        pairs[index + 1] = 0
                self.put(request.requestor, prop, value.atom, value.bits, struct.pack(f"={len(pairs)}I", *pairs))
            except UndoError:
                ok = False
        elif ok:
            ok = self._serve(request.requestor, request.target, prop)
        event = Event()
        event.selection = Selection(SELECTION_NOTIFY, 0, 1, self.display, request.requestor, request.selection,
                                    request.target, prop if ok else 0, request.time)
        self.x.XSendEvent(self.display, request.requestor, 0, 0, C.byref(event))

    def text(self, data: bytes) -> X11Snapshot:
        atoms = [self.atom(name) for name in ("UTF8_STRING", "text/plain;charset=utf-8", "text/plain")]
        return {atom: X11Format(atom, 8, data) for atom in atoms}

    def publish(self, data: X11Snapshot) -> X11Stamp:
        self.data = data
        self.x.XSetSelectionOwner(self.display, self.clipboard, self.window if data else 0, CURRENT_TIME)
        self.sync()
        stamp = self.stamp()
        if data and stamp.owner != self.window:
            self.data = {}
            raise UndoError("Clipboard-Schreiben wurde abgewiesen.", 3)
        return stamp

    def close(self) -> None:
        display = self.display
        if not display:
            return
        try:
            try:
                if self.window:
                    self.x.XDestroyWindow(display, self.window)
            finally:
                self.x.XCloseDisplay(display)
        finally:
            self.window = self.display = 0
            if X11._displays.pop(display, None) is not None and not X11._displays:
                self.x.XSetErrorHandler(X11._previous_handler)
                X11._previous_handler = None


def unpack_words(data: bytes) -> tuple[int, ...]:
    return struct.unpack(f"={len(data) // 4}I", data)


def _handle_x_error(display: Optional[int], error: int) -> int:
    # Xlib hat einen prozessweiten Handler für alle offenen Displays.
    clipboard = X11._displays.get(display) if display is not None else None
    if clipboard is not None:
        clipboard._error(C.cast(error, C.POINTER(XError)).contents)
    elif X11._previous_handler:
        handler = C.cast(X11._previous_handler, ErrorHandler)
        return int(handler(display, error))
    return 0


_X_ERROR_HANDLER = ErrorHandler(_handle_x_error)
