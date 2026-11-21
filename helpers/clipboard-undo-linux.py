#!/usr/bin/env python3
"""Einmaliges vollständiges Clipboard-Undo. Nutzdaten bleiben im Daemon-RAM."""
import sys


if __name__ == "__main__":
    if sys.version_info < (3, 8):
        if sys.argv[1:] == ["diagnose"]:
            print("python-unsupported")
            sys.exit(0)
        print("Clipboard-Undo benötigt Linux und Python 3.8 oder neuer.", file=sys.stderr)
        sys.exit(2)

    from clipboard_undo.cli import main

    sys.exit(main(sys.argv))
