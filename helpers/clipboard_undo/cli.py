from __future__ import annotations

from contextlib import closing
import json
import os
import struct
import subprocess
import sys
import time
from typing import Sequence

from .backends import backend, dependencies, diagnose
from .common import MAX_BYTES, READ_TIMEOUT, TOTAL_TIMEOUT, UndoError
from .daemon import REQUEST_LENGTH, connect, private_directory, serve
from .state import status

def client(entry: str, command: str, token: str = "") -> str:
    if command == "diagnose":
        return diagnose()
    if command == "dependencies":
        dependencies()
        return ""
    if command == "available":
        with closing(backend(probe=True)):
            return ""
    try:
        path, directory_fd = private_directory(create=command != "status")
    except FileNotFoundError:
        if command == "status":
            return status()
        raise
    socket_path = os.path.join(path, "control.sock")
    if command == "__daemon":
        serve(path, directory_fd)
        return ""
    os.close(directory_fd)
    try:
        connection = connect(socket_path)
    except (FileNotFoundError, ConnectionRefusedError):
        if command != "prepare":
            if command == "status":
                return status()
            if command in ("cancel", "stop"):
                return ""
            raise UndoError("Kein gültiges Clipboard-Undo verfügbar.")
        process = subprocess.Popen([sys.executable, os.path.realpath(entry), "__daemon"],
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
        connection.sendall(REQUEST_LENGTH.pack(len(request)) + request)
        if data:
            connection.sendall(data)
        response = bytearray()
        while b"\n" not in response:
            part = connection.recv(1024)
            if not part or len(response) + len(part) > 4096:
                raise UndoError("Clipboard-Undo-Dienst hat keine gültige Antwort geliefert.", 2)
            response.extend(part)
        result = json.loads(response)
        if result["code"]:
            raise UndoError(result["error"], result["code"])
        response_text: str = result["result"]
        return response_text


def main(argv: Sequence[str]) -> int:
    commands = ("dependencies", "available", "diagnose", "status", "prepare", "replace", "cancel", "undo", "stop", "__daemon")
    try:
        if len(argv) < 2 or argv[1] not in commands:
            raise UndoError(
                "Aufruf: clipboard-undo-linux.py dependencies|available|diagnose|status [TOKEN]|"
                "prepare|replace TOKEN|cancel TOKEN|undo", 2,
            )
        command = argv[1]
        valid_counts = (2, 3) if command == "status" else (3,) if command in ("replace", "cancel") else (2,)
        if len(argv) not in valid_counts:
            raise UndoError("Ungültiger Clipboard-Undo-Aufruf.", 2)
        result = client(argv[0], command, argv[2] if len(argv) == 3 else "")
        if result:
            print(result)
    except UndoError as error:
        print(str(error), file=sys.stderr)
        return error.code
    except (OSError, ValueError, KeyError, struct.error):
        print("Clipboard-Undo-Dienst oder Sitzungsverbindung nicht verfügbar.", file=sys.stderr)
        return 2
    return 0
