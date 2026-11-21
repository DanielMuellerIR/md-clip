from __future__ import annotations

import select
import time
from typing import Protocol, TypeVar, Union


MAX_BYTES = 64 * 1024 * 1024
MAX_TYPES = 128
MAX_TRANSFERS = 32
IO_CHUNK = 64 * 1024
TTL = 600
READ_TIMEOUT = 5
TOTAL_TIMEOUT = 30
POLL_INTERVAL = 0.05


class UndoError(Exception):
    def __init__(self, message: str, code: int = 1, reason: str = "undo-helper-failed") -> None:
        super().__init__(message)
        self.code = code
        self.reason = reason


class Selectable(Protocol):
    def fileno(self) -> int:
        ...


def deadline_wait(fd: Union[int, Selectable], deadline: float) -> None:
    remaining = deadline - time.monotonic()
    if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
        raise UndoError("Zeitlimit beim Lesen des Clipboards erreicht.")


Stamp = TypeVar("Stamp", covariant=True)
Snapshot = TypeVar("Snapshot")


class Clipboard(Protocol[Stamp, Snapshot]):
    owned: bool

    def stamp(self) -> Stamp:
        ...

    def capture(self) -> tuple[Stamp, Snapshot]:
        ...

    def text(self, data: bytes) -> Snapshot:
        ...

    def publish(self, data: Snapshot) -> Stamp:
        ...

    def pump(self, timeout: float = 0) -> None:
        ...

    def fileno(self) -> int:
        ...

    def write_fds(self) -> list[int]:
        ...
