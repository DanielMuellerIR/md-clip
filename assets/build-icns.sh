#!/usr/bin/env bash
# assets/build-icns.sh — Wandelt das 1024×1024 Master-Icon in ein
# macOS-.icns-File um. macOS-Apps brauchen ein .icns mit mehreren
# Größen, sonst sieht das Icon in kleinen Kontexten (z.B. Mission
# Control, Finder-Detail-Spalte) pixelig aus.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER="$SCRIPT_DIR/md-clip-icon-master.png"
ICONSET="$SCRIPT_DIR/md-clip.iconset"
OUT="$SCRIPT_DIR/md-clip.icns"

if [ ! -f "$MASTER" ]; then
  echo "FEHLER: Master-Icon nicht gefunden: $MASTER" >&2
  echo "       Erst 'python3 assets/generate-icon-v2.py' ausführen." >&2
  exit 1
fi

# Iconset-Verzeichnis frisch anlegen. iconutil erwartet die Namen exakt.
rm -rf "$ICONSET"
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

# Iconset-Zwischenverzeichnis nicht mehr nötig.
rm -rf "$ICONSET"

echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
