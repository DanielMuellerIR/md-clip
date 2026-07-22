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
# APP_VERSION NICHT hardcoden — sonst driftet die Bundle-Version von der
# echten Version in bin/md-clip weg. Sie wird weiter unten (nach dem Setzen
# von PROJECT_ROOT) aus bin/md-clip abgeleitet — dieselbe Single-Source-of-
# Truth wie in wrappers/sign-and-release.sh.

# Mindest-macOS für das Bundle. 11.0 (Big Sur) ist die erste Version mit
# nativer Apple-Silicon-Unterstützung und gleichzeitig der Cutoff, bis
# zu dem pandoc-Universal-Binaries verfügbar sind.
MIN_MACOS="11.0"

# Pandoc-Version. Pinning macht den Build reproduzierbar. Bei Updates
# diese Zahl bumpen und neu bauen.
PANDOC_VERSION="3.9.0.2"
PANDOC_ZIP_SHA256="6e9eca844076bcbb599bbeebbba78a70f93b5307782b85c2c272872812c88875"
PANDOC_COPYRIGHT_SHA256="842e33ef01625e93f85bebb8bac83aa570186b7aa77a09971257cc29f8f60740"

# ---------- Pfade ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=verified-cache.sh
source "$SCRIPT_DIR/verified-cache.sh"

# Versions-String aus dem md-clip-Skript ziehen — Single Source of Truth,
# identisch zu wrappers/sign-and-release.sh. Landet unten im Info.plist als
# CFBundleShortVersionString/CFBundleVersion.
APP_VERSION=$(grep '^VERSION=' "$PROJECT_ROOT/bin/md-clip" | head -1 | cut -d'"' -f2)

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
PANDOC_URL="https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-arm64-macOS.zip"
if sha256_matches "$PANDOC_ZIP" "$PANDOC_ZIP_SHA256"; then
  echo "✓ Verifiziertes pandoc-arm64 aus Cache: $PANDOC_ZIP"
else
  echo "==> Lade und verifiziere $PANDOC_URL"
  download_verified "$PANDOC_URL" "$PANDOC_ZIP_SHA256" "$PANDOC_ZIP" || exit 1
fi

# Immer aus dem verifizierten Archiv in ein privates Staging-Verzeichnis
# entpacken. Nur der dokumentierte Archivpfad ist zulässig; ein zusätzlich
# eingeschleustes ausführbares `pandoc` kann nicht ausgewählt werden.
PANDOC_ARCHIVE_ROOT="pandoc-${PANDOC_VERSION}-arm64"
PANDOC_ARCHIVE_BIN="$PANDOC_ARCHIVE_ROOT/bin/pandoc"
PANDOC_STAGE=$(mktemp -d "$BUILD_DIR/.pandoc-extract.XXXXXX")
PANDOC_BUILD_TMP=$(mktemp "$BUILD_DIR/.pandoc-binary.XXXXXX")
cleanup_pandoc_stage() {
  rm -rf "$PANDOC_STAGE"
  rm -f "$PANDOC_BUILD_TMP"
}
trap cleanup_pandoc_stage EXIT INT TERM

unzip -q "$PANDOC_ZIP" "$PANDOC_ARCHIVE_BIN" -d "$PANDOC_STAGE"
PANDOC_BIN="$PANDOC_STAGE/$PANDOC_ARCHIVE_BIN"
chmod +x "$PANDOC_BIN"
if ! verify_pandoc_version "$PANDOC_BIN" "$PANDOC_VERSION"; then
  echo "FEHLER: Entpacktes pandoc meldet nicht Version $PANDOC_VERSION." >&2
  exit 1
fi

cp "$PANDOC_BIN" "$PANDOC_BUILD_TMP"
chmod +x "$PANDOC_BUILD_TMP"
mv -f "$PANDOC_BUILD_TMP" "$BUILD_DIR/pandoc"
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
cp "$PROJECT_ROOT/lib/pipeline.sh" "$APP_BUNDLE/Contents/Resources/bin/pipeline.sh"
cp "$BUILD_DIR/clipboard-html"     "$APP_BUNDLE/Contents/Resources/bin/clipboard-html"
cp "$BUILD_DIR/clipboard-rtf"      "$APP_BUNDLE/Contents/Resources/bin/clipboard-rtf"
cp "$BUILD_DIR/pandoc"             "$APP_BUNDLE/Contents/Resources/bin/pandoc"

# Icon-Datei mitliefern. .icns muss in Contents/Resources/ liegen und im
# Info.plist als CFBundleIconFile referenziert werden, damit macOS es im
# Dock, Finder und Launchpad anzeigt.
ICNS_SOURCE="$PROJECT_ROOT/assets/md-clip.icns"
if [ -f "$ICNS_SOURCE" ]; then
  cp "$ICNS_SOURCE" "$APP_BUNDLE/Contents/Resources/md-clip.icns"
  echo "✓ Icon mitgeliefert"
else
  echo "WARNUNG: kein Icon gefunden unter $ICNS_SOURCE" >&2
  echo "         (App bekommt das macOS-Standard-Icon)" >&2
fi

chmod +x "$APP_BUNDLE/Contents/Resources/bin/"*

# ---------- 5. Launcher in MacOS/ ----------

# Das ist die Datei, die macOS beim Doppelklick auf die .app ausführt.
# Den eigentlichen Launcher pflegen wir in einer separaten Datei
# (wrappers/launcher.sh), die hier nur kopiert wird. Vorteile:
#   - Syntax-Highlighting im Editor
#   - Diffs lesbarer
#   - Wiederverwendbar testbar (z.B. lokal ausführbar)
cp "$SCRIPT_DIR/launcher.sh" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
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
    <key>CFBundleIconFile</key>
    <string>md-clip</string>
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

# COPYRIGHT wird wie das Binary gepinnt und im Cache verifiziert. Ein
# Offline-Build darf niemals still ein leeres Lizenzdokument ausliefern.
PANDOC_COPYRIGHT_URL="https://raw.githubusercontent.com/jgm/pandoc/${PANDOC_VERSION}/COPYRIGHT"
PANDOC_COPYRIGHT_CACHE="$CACHE_DIR/pandoc-${PANDOC_VERSION}-COPYRIGHT"
download_verified \
  "$PANDOC_COPYRIGHT_URL" \
  "$PANDOC_COPYRIGHT_SHA256" \
  "$PANDOC_COPYRIGHT_CACHE" || exit 1
test -s "$PANDOC_COPYRIGHT_CACHE"
cp "$PANDOC_COPYRIGHT_CACHE" "$LIC_DIR/pandoc-COPYRIGHT.txt"

cat > "$LIC_DIR/README.txt" <<NOTE
md-clip enthält ein unverändert weiterverteiltes pandoc-Binary
(Version ${PANDOC_VERSION}), veröffentlicht unter der GNU General
Public License (GPL). Der vollständige Lizenztext steht in
pandoc-COPYRIGHT.txt.

Pandoc-Quellcode: https://github.com/jgm/pandoc/tree/${PANDOC_VERSION}

Schriftliches Angebot (GPL): Der vollständige Quellcode dieser pandoc-
Version wird auf Anfrage für mindestens drei Jahre bereitgestellt.
Kontakt: siehe GitHub-Repo DanielMuellerIR/md-clip (Issues oder Discussions)

md-clip selbst steht unter der MIT-Lizenz. MIT- und GPL-Komponenten
werden hier als Aggregation distribuiert — nicht als abgeleitetes Werk.
NOTE

# ---------- Fertig ----------

echo
echo "==> Bundle gebaut (unsigniert)"
echo "    $APP_BUNDLE"
echo "    Größe: $(du -sh "$APP_BUNDLE" | cut -f1)"
echo
echo "Nächster Schritt zum Verteilen: wrappers/sign-and-release.sh"
echo "(signiert, paketiert und notarisiert das Bundle in ein DMG.)"
