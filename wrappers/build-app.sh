#!/usr/bin/env bash
# wrappers/build-app.sh — Erzeugt md-clip.app, eine ins Dock ziehbare
# macOS-App, die per Klick `md-clip --replace --notify` aufruft.
#
# Hintergrund: macOS bietet zwei Wege, eine Shell-Befehl-App zu erzeugen:
#
#   1. Automator.app → Neues Dokument → "Programm" → Shell-Skript-Aktion
#      → Speichern als .app  (GUI-Weg, nicht automatisierbar)
#
#   2. osacompile-Befehl → AppleScript wickelt den Shell-Aufruf ein
#      (CLI-Weg, automatisierbar — den nehmen wir hier)
#
# Beide produzieren funktional dasselbe: ein .app-Bundle, das beim
# Doppelklick einen Shell-Befehl ausführt. osacompile ist kürzer
# und reproduzierbar.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="md-clip.app"
TARGET="$SCRIPT_DIR/$APP_NAME"

# Falls schon vorhanden: alte Version löschen, damit osacompile nicht meckert.
# rm -rf ist hier ok, weil das Ziel-Verzeichnis fest hier im Projekt liegt.
if [ -e "$TARGET" ]; then
  echo "==> Alte $APP_NAME entfernen"
  rm -rf "$TARGET"
fi

echo "==> $APP_NAME bauen"

# osacompile -o ZIEL.app -e 'AppleScript-Code'
# Der AppleScript-Code ruft md-clip auf und zeigt bei Fehler eine
# Notification. `try ... on error` fängt non-zero Exits ab.
osacompile -o "$TARGET" -e '
try
    do shell script "/usr/local/bin/md-clip --replace --notify"
on error errMsg
    display notification "Clipboard nicht konvertierbar" with title "md-clip"
end try
'

echo "✓ $TARGET erstellt"
echo
echo "Nächste Schritte:"
echo "  1. App ins Dock ziehen."
echo "  2. Optional: eigenes Icon zuweisen — Rechtsklick → Informationen,"
echo "     dann ein Icon-Bild auf das kleine App-Symbol oben links ziehen."
