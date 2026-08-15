#!/usr/bin/env bash
# assets/build-icns.sh — Wandelt das 1024×1024 Master-Icon in ein
# macOS-.icns-File um. macOS-Apps brauchen ein .icns mit mehreren
# Größen, sonst sieht das Icon in kleinen Kontexten (z.B. Mission
# Control, Finder-Detail-Spalte) pixelig aus.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER="$SCRIPT_DIR/md-clip-icon-master.png"
OUT="$SCRIPT_DIR/md-clip.icns"

if [ ! -f "$MASTER" ]; then
  echo "FEHLER: Master-Icon nicht gefunden: $MASTER" >&2
  echo "       Erst 'python3 assets/generate-icon-v2.py' ausführen." >&2
  exit 1
fi

# Ein falsches Seitenverhältnis würde `sips -z` unbemerkt auf ein Quadrat
# verzerren. Das Master-Icon ist deshalb Teil des Eingabevertrags.
MASTER_WIDTH=$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth/{print $2; exit}')
MASTER_HEIGHT=$(sips -g pixelHeight "$MASTER" | awk '/pixelHeight/{print $2; exit}')
if [ "$MASTER_WIDTH" != "1024" ] || [ "$MASTER_HEIGHT" != "1024" ]; then
  echo "FEHLER: Master-Icon muss 1024×1024 Pixel groß sein (ist ${MASTER_WIDTH:-?}×${MASTER_HEIGHT:-?})." >&2
  exit 1
fi

# Privates Zwischenverzeichnis statt eines festen Pfads unter assets/: Ein
# abgebrochener oder paralleler Lauf kann dadurch weder fremde Dateien löschen
# noch mit einem zweiten Lauf kollidieren. iconutil erwartet die Endung
# `.iconset`, deshalb liegt das eigentliche Verzeichnis in einer mktemp-Hülle.
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/md-clip-icon.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT INT TERM
ICONSET="$TEMP_ROOT/md-clip.iconset"
mkdir -p "$ICONSET"

# Die zehn Größen, die Apple-Apps standardmäßig mitliefern.
# Format: dimension:dateiname
declare -a SIZES=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
  dim="${entry%%:*}"
  name="${entry##*:}"
  # sips ist macOS-Bordmittel zur Bildverarbeitung. -z height width
  # skaliert proportional auf die exakte Quadrat-Größe.
  sips -z "$dim" "$dim" "$MASTER" --out "$ICONSET/$name" >/dev/null
done

# iconutil packt das ganze iconset-Verzeichnis in eine .icns-Datei.
iconutil --convert icns "$ICONSET" -o "$OUT"

echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
