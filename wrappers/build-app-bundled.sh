#!/usr/bin/env bash
# wrappers/build-app-bundled.sh — Baut eine vollständig self-contained
# md-clip.app inkl. pandoc-Binary. Zielgruppe: Nutzer ohne Terminal,
# die einfach eine .app herunterladen, ins Programme-Verzeichnis ziehen
# und nutzen wollen.
#
# Diese Stufe ist UNSIGNIERT — beim ersten Start zeigt macOS den
# Gatekeeper-Hinweis „Apple konnte Schadsoftware nicht prüfen". Für die
# spätere signierte+notarisierte Variante siehe Stufe B (kommt separat).
#
# Voraussetzungen:
#   - swiftc (Xcode Command Line Tools)
#   - curl, unzip, lipo (alle macOS-Bordmittel)
#   - Internet-Zugang für pandoc-Download
#
# Output: build/md-clip.app

set -euo pipefail

# ---------- Konstanten ----------

# Bundle-ID nach Reverse-DNS-Konvention. github.io-Namespace, weil das
# Projekt auf github.com/DanielMuellerIR liegt — auch wenn keine
# GitHub-Pages-Seite existiert, ist die Domain rechtlich uns.
BUNDLE_ID="io.github.danielmuellerir.md-clip"
APP_NAME="md-clip"
APP_VERSION="1.0.0"

# Mindest-macOS für das Bundle. 11.0 (Big Sur) ist die erste Version mit
# nativer Apple-Silicon-Unterstützung und gleichzeitig der Cutoff, bis
# zu dem pandoc-Universal-Binaries verfügbar sind.
MIN_MACOS="11.0"

# Pandoc-Version. Pinning macht den Build reproduzierbar. Bei Updates
# diese Zahl bumpen und neu bauen.
PANDOC_VERSION="3.5"

# ---------- Pfade ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
CACHE_DIR="$BUILD_DIR/cache"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# ---------- Aufräumen + Verzeichnisse ----------

# Cache überleben lassen — pandoc-Downloads sind groß (~50 MB pro Arch).
# Nur das alte App-Bundle wegputzen.
rm -rf "$APP_BUNDLE"
mkdir -p "$CACHE_DIR"

echo "==> Build-Verzeichnis: $BUILD_DIR"

# ---------- 1. Pandoc-Binary für arm64 holen ----------

# Wir bauen nur für Apple Silicon. Intel-Support wäre +140 MB pro Binary
# (Pandoc ist statisch gelinktes Haskell mit Runtime). Da seit 2020 alle
# neuen Macs arm64 sind, ist der Tradeoff klar gegen Universal.
# Falls später doch Intel gebraucht wird: zweite arch hier dazu, lipo
# zum Mergen.

PANDOC_ZIP="$CACHE_DIR/pandoc-${PANDOC_VERSION}-arm64.zip"
if [ ! -f "$PANDOC_ZIP" ]; then
  PANDOC_URL="https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-arm64-macOS.zip"
  echo "==> Lade $PANDOC_URL"
  curl -fsSL --output "$PANDOC_ZIP" "$PANDOC_URL"
else
  echo "✓ pandoc-arm64 aus Cache: $PANDOC_ZIP"
fi

PANDOC_EXTRACT_DIR="$CACHE_DIR/pandoc-arm64"
if [ ! -d "$PANDOC_EXTRACT_DIR" ]; then
  mkdir -p "$PANDOC_EXTRACT_DIR"
  unzip -q "$PANDOC_ZIP" -d "$PANDOC_EXTRACT_DIR"
fi

# Binary aus dem entpackten Tree finden (Zip enthält pandoc-VERSION-arm64-macOS/bin/pandoc).
PANDOC_BIN=$(find "$PANDOC_EXTRACT_DIR" -name pandoc -type f -perm -u+x | head -1)
if [ -z "$PANDOC_BIN" ]; then
  echo "FEHLER: pandoc-Binary nach Entpacken nicht gefunden." >&2
  exit 1
fi

# Kopie ins Build-Verzeichnis ablegen, von dort wandert sie ins Bundle.
cp "$PANDOC_BIN" "$BUILD_DIR/pandoc"
echo "✓ pandoc bereit ($(du -h "$BUILD_DIR/pandoc" | cut -f1))"

# ---------- 2. Swift-Helper kompilieren ----------

for helper in clipboard-html clipboard-rtf; do
  src="$PROJECT_ROOT/helpers/${helper}.swift"
  out="$BUILD_DIR/${helper}"
  echo "==> Kompiliere ${helper}"
  # -target setzt sowohl Architektur als auch Mindest-OS-Version in einem.
  swiftc -target "arm64-apple-macos${MIN_MACOS}" "$src" -o "$out"
done

# ---------- 4. .app-Bundle-Struktur ----------

echo "==> Erstelle .app-Struktur"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/bin"
mkdir -p "$APP_BUNDLE/Contents/Resources/Licenses"

# md-clip-Skript und Helper kopieren
cp "$PROJECT_ROOT/bin/md-clip"     "$APP_BUNDLE/Contents/Resources/bin/md-clip"
cp "$BUILD_DIR/clipboard-html"     "$APP_BUNDLE/Contents/Resources/bin/clipboard-html"
cp "$BUILD_DIR/clipboard-rtf"      "$APP_BUNDLE/Contents/Resources/bin/clipboard-rtf"
cp "$BUILD_DIR/pandoc"             "$APP_BUNDLE/Contents/Resources/bin/pandoc"

chmod +x "$APP_BUNDLE/Contents/Resources/bin/"*

# ---------- 5. Launcher in MacOS/ ----------

# Das ist die Datei, die macOS beim Doppelklick auf die .app ausführt.
# Wir schreiben einen kleinen Bash-Launcher, der das eigentliche md-clip
# aus Resources/bin/ mit --replace --notify aufruft.
cat > "$APP_BUNDLE/Contents/MacOS/$APP_NAME" <<'LAUNCHER'
#!/bin/bash
# md-clip.app-Launcher.
# Findet die Resources/bin/-Pfade relativ zu sich selbst und ruft md-clip auf.
DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/../Resources/bin/md-clip" --replace --notify
LAUNCHER
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# ---------- 6. Info.plist ----------

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>md-clip</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Daniel Müller. MIT License.</string>
</dict>
</plist>
PLIST

# LSUIElement=true sagt macOS: das ist eine „Agent"-App ohne Dock-Icon
# und ohne Menüleiste. Sie taucht beim Doppelklick auf, macht ihre
# Arbeit und verschwindet wieder. Genau das wollen wir — keine GUI.

# ---------- 7. pandoc-Lizenz mitliefern (GPL-Pflicht) ----------

echo "==> Lade pandoc-Lizenz und COPYRIGHT-Hinweis"
LIC_DIR="$APP_BUNDLE/Contents/Resources/Licenses"

# GPL-Volltext von pandocs Repo holen (gleicher Tag wie die Binary).
curl -fsSL \
  "https://raw.githubusercontent.com/jgm/pandoc/${PANDOC_VERSION}/COPYRIGHT" \
  > "$LIC_DIR/pandoc-COPYRIGHT.txt" \
  || echo "WARNUNG: pandoc-COPYRIGHT konnte nicht geladen werden (Offline-Build?)"

cat > "$LIC_DIR/README.txt" <<NOTE
md-clip enthält ein unverändert weiterverteiltes pandoc-Binary
(Version ${PANDOC_VERSION}), veröffentlicht unter der GNU General
Public License (GPL). Der vollständige Lizenztext steht in
pandoc-COPYRIGHT.txt.

Pandoc-Quellcode: https://github.com/jgm/pandoc/tree/${PANDOC_VERSION}

md-clip selbst steht unter der MIT-Lizenz. MIT- und GPL-Komponenten
werden hier als Aggregation distribuiert — nicht als abgeleitetes Werk.
NOTE

# ---------- Fertig ----------

echo
echo "==> Fertig"
echo "    Bundle:  $APP_BUNDLE"
echo "    Größe:   $(du -sh "$APP_BUNDLE" | cut -f1)"
echo
echo "Test:"
echo "  open \"$APP_BUNDLE\""
echo "  (Beim ersten Start kommt Gatekeeper-Warnung — das ist normal für"
echo "   unsignierte Apps. Rechtsklick → Öffnen umgeht das.)"
