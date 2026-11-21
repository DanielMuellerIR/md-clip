from __future__ import annotations

from dataclasses import dataclass
import json
import secrets
import time
from typing import Callable, Generic, Optional

from .common import Clipboard, MAX_BYTES, Snapshot, Stamp, TTL, UndoError


@dataclass(frozen=True)
class SavedClipboard(Generic[Stamp, Snapshot]):
    stamp: Stamp
    snapshot: Snapshot
    expires: float


@dataclass(frozen=True)
class PreparedClipboard(Generic[Stamp, Snapshot]):
    token: str
    original: SavedClipboard[Stamp, Snapshot]

    def matches(self, token: str) -> bool:
        return secrets.compare_digest(token, self.token)


def status(undo_available: bool = False, pending_valid: bool = False) -> str:
    return json.dumps({"version": 1, "undo_available": undo_available, "pending_valid": pending_valid})


class State(Generic[Stamp, Snapshot]):
    def __init__(self, clipboard: Clipboard[Stamp, Snapshot], clock: Callable[[], float] = time.monotonic) -> None:
        self.clipboard = clipboard
        self.clock = clock
        self.pending: Optional[PreparedClipboard[Stamp, Snapshot]] = None
        self.saved: Optional[SavedClipboard[Stamp, Snapshot]] = None

    def expire(self) -> None:
        now = self.clock()
        stamp = self.clipboard.stamp()
        if self.pending and (now >= self.pending.original.expires or stamp != self.pending.original.stamp):
            self.pending = None
        if self.saved and (now >= self.saved.expires or stamp != self.saved.stamp):
            self.saved = None

    def cancel(self, token: str) -> None:
        if self.pending and self.pending.matches(token):
            self.pending = None

    def command(self, name: str, token: str = "", data: bytes = b"") -> str:
        self.expire()
        if name == "status":
            return status(self.saved is not None, bool(self.pending and self.pending.matches(token)))
        if name == "prepare":
            if self.pending:
                raise UndoError("Eine Clipboard-Konvertierung ist bereits vorbereitet.")
            stamp, snapshot = self.clipboard.capture()
            token = secrets.token_hex(32)
            self.pending = PreparedClipboard(token, SavedClipboard(stamp, snapshot, self.clock() + TTL))
            return token
        if name == "cancel":
            self.cancel(token)
            return ""
        if name == "replace":
            if not self.pending or not self.pending.matches(token):
                raise UndoError("Clipboard-Sicherung fehlt oder ist abgelaufen.")
            original = self.pending.original
            self.pending = None
            if self.clipboard.stamp() != original.stamp:
                raise UndoError("Clipboard wurde seit der Sicherung geändert.")
            try:
                data.decode("utf-8")
            except UnicodeError:
                raise UndoError("Die Markdown-Ausgabe ist kein UTF-8-Text.", 3)
            if len(data) > MAX_BYTES:
                raise UndoError("Markdown-Ausgabe überschreitet 64 MiB.", 3)
            stamp = self.clipboard.publish(self.clipboard.text(data))
            self.saved = SavedClipboard(stamp, original.snapshot, self.clock() + TTL)
            return ""
        if name == "undo":
            if not self.saved:
                raise UndoError("Kein gültiges Clipboard-Undo verfügbar.")
            saved, self.saved = self.saved, None
            if self.clipboard.stamp() != saved.stamp:
                raise UndoError("Clipboard wurde nach der Konvertierung geändert.")
            self.clipboard.publish(saved.snapshot)
            return ""
        raise UndoError("Unbekannter Clipboard-Undo-Aufruf.", 2)
