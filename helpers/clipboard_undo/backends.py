from __future__ import annotations

from contextlib import closing
import ctypes as C
import ctypes.util
import os
import socket
import stat
import struct
import sys
from typing import Union

from .common import UndoError
from .wayland import Wayland
from .x11 import X11

def dependencies() -> None:
    if sys.platform != "linux" or sys.version_info < (3, 8):
        raise UndoError("Clipboard-Undo benötigt Linux und Python 3.8 oder neuer.", 2, "python-unsupported")
    if not hasattr(socket, "SO_PEERCRED") or not hasattr(os, "O_NOFOLLOW"):
        raise UndoError("Sichere lokale Clipboard-Undo-Verbindungen werden nicht unterstützt.", 2, "local-security-unsupported")
    if not os.environ.get("WAYLAND_DISPLAY"):
        try:
            for name in ("X11", "Xfixes"):
                library = C.util.find_library(name)
                if not library:
                    raise OSError()
                C.CDLL(library)
        except OSError:
            raise UndoError("X11-Undo benötigt libX11 und libXfixes.", 2, "x11-libraries-missing")


def backend(probe: bool = False) -> Union[Wayland, X11]:
    if sys.platform != "linux":
        raise UndoError("Dieser Clipboard-Helfer benötigt Linux.", 2)
    return Wayland(probe) if os.environ.get("WAYLAND_DISPLAY") else X11(probe)


def diagnose() -> str:
    """Nur Bibliotheken, Sitzung und Protokoll prüfen; keine Selection binden."""
    try:
        dependencies()
        runtime = os.environ.get("XDG_RUNTIME_DIR", "")
        if os.environ.get("WAYLAND_DISPLAY") and not runtime:
            return "wayland-runtime-missing"
        if runtime:
            try:
                info = os.lstat(runtime)
            except OSError:
                return "runtime-unsafe"
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                return "runtime-unsafe"
        if not os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("DISPLAY"):
            return "x11-session-missing"
        with closing(backend(probe=True)):
            return "ok"
    except UndoError as error:
        return error.reason
    except (OSError, ValueError, KeyError, AttributeError, struct.error):
        return "undo-helper-failed"
