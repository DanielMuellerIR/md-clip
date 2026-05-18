#!/usr/bin/env bash
# tests/compare-file.sh — Reproduzierbarer Vergleichs-Lauf mit Datei-Input.
#
# Statt von einem unbekannten Clipboard-Zustand auszugehen, laden wir
# eine vorgegebene Datei mit dem passenden Flavor aufs Clipboard und
# starten dann compare.sh wie gewohnt.
#
# Aufruf:
#   tests/compare-file.sh tests/fixtures/word-rtf.rtf
#   tests/compare-file.sh meine-datei.html
#
# Unterstützte Endungen: .rtf, .html / .htm, .txt
# RTFD-Bundles werden (noch) nicht unterstützt — die brauchen einen
# eigenen Pfad, weil RTFD ein Verzeichnis ist, kein einzelnes File.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# --- Argument-Check ---
if [ $# -ne 1 ]; then
  echo "Usage: $0 <datei.rtf|datei.html|datei.txt>" >&2
  exit 2
fi

file="$1"
if [ ! -f "$file" ]; then
  echo "Datei nicht gefunden: $file" >&2
  exit 2
fi

# Absoluten Pfad bilden — der Swift-Helper kriegt nur Argumente, kein cwd.
abs="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"

# Endung extrahieren, in Kleinbuchstaben.
ext="${file##*.}"
ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

# --- Loader-Helper bei Bedarf kompilieren ---
LOADER_SRC="tests/load-clipboard.swift"
LOADER_BIN="tests/load-clipboard"
if [ ! -x "$LOADER_BIN" ] || [ "$LOADER_SRC" -nt "$LOADER_BIN" ]; then
  echo "==> Kompiliere $LOADER_SRC"
  swiftc "$LOADER_SRC" -o "$LOADER_BIN"
fi

# --- Datei mit dem passenden Flavor aufs Clipboard laden ---
case "$ext" in
  rtf)
    echo "==> Lade $file als public.rtf"
    ./"$LOADER_BIN" "public.rtf" "$abs"
    ;;
  html|htm)
    echo "==> Lade $file als public.html"
    ./"$LOADER_BIN" "public.html" "$abs"
    ;;
  txt)
    echo "==> Lade $file als Plain Text (via pbcopy)"
    pbcopy < "$abs"
    ;;
  *)
    echo "Unbekannte Endung: .$ext (unterstützt: .rtf, .html/.htm, .txt)" >&2
    exit 2
    ;;
esac

echo
echo "==> Aktuelle Clipboard-Flavors:"
osascript -e 'clipboard info' 2>/dev/null || true
echo
echo "==> compare.sh"
echo

# Dateiname als Basis übergeben — sonst nimmt compare.sh das pbpaste-
# Resultat, das bei reinem RTF-Clipboard nur die RTF-Quelltext-Bytes liefert.
basename_no_ext="$(basename "$file")"
basename_no_ext="${basename_no_ext%.*}"
export BASENAME_OVERRIDE="$basename_no_ext"

bash "$PROJECT_ROOT/tests/compare.sh"
