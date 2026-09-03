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
#   - curl, unzip, tar, codesign, ditto und shasum (macOS-Bordmittel)
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

# Mindest-macOS für das Bundle. Das gepinnte pandoc 3.9.0.2 trägt selbst
# LC_BUILD_VERSION minos 14.0; ein niedrigerer Wert in Info.plist ließe die App
# auf älteren Systemen starten, obwohl jede Konvertierung am Binary scheitert.
# verify-bundle.sh prüft diese Grenze für alle ausführbaren Bundle-Bestandteile.
MIN_MACOS="14.0"

# Pandoc-Version. Pinning macht den Build reproduzierbar. Bei Updates
# diese Zahl bumpen und neu bauen.
PANDOC_VERSION="3.9.0.2"
PANDOC_ZIP_SHA256="6e9eca844076bcbb599bbeebbba78a70f93b5307782b85c2c272872812c88875"
PANDOC_COPYRIGHT_SHA256="842e33ef01625e93f85bebb8bac83aa570186b7aa77a09971257cc29f8f60740"

# Sparkle-Version (Update-Framework). Exakt gepinnt, weil der Updater die
# installierte App austauscht: Ein Versionssprung wird bewusst geprüft, nie
# still aufgelöst — dieselbe Regel wie in poormans_text. Die Prüfsumme wurde
# am 2026-08-06 gegen den unabhängig gepflegten Wert im Homebrew-Cask
# `sparkle` gegenverifiziert (Cask-Commit ae0cb300).
SPARKLE_VERSION="2.9.4"
SPARKLE_TAR_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"

# ---------- Pfade ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=verified-cache.sh
source "$SCRIPT_DIR/verified-cache.sh"

# Versions-String aus dem md-clip-Skript ziehen — Single Source of Truth,
# identisch zu wrappers/sign-and-release.sh. Landet unten im Info.plist als
# CFBundleShortVersionString/CFBundleVersion.
APP_VERSION=$(awk -F'"' '/^VERSION=/{print $2; exit}' "$PROJECT_ROOT/bin/md-clip")
if [ -z "$APP_VERSION" ]; then
  echo "FEHLER: VERSION fehlt oder ist nicht in Anführungszeichen gesetzt: bin/md-clip." >&2
  exit 65
fi

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

# Alles Temporäre dieses Laufs hängt an diesen drei Variablen. Aufräumroutine
# und Trap stehen bewusst VOR dem ersten `mktemp`: Wird der Build zwischen dem
# Anlegen und dem Registrieren abgebrochen, bliebe sonst ein Staging-Verzeichnis
# in build/ liegen. Dieselbe Reihenfolge halten install-app.sh und
# wrappers/sign-and-release.sh ein. Ohne eigenes `exit` liefe das Skript hinter
# dem Trap weiter; 130/143 sind die üblichen Codes für INT und TERM.
PANDOC_STAGE=""
PANDOC_BUILD_TMP=""
SPARKLE_STAGE=""
cleanup_build_stages() {
  if [ -n "$PANDOC_STAGE" ]; then
    rm -rf "$PANDOC_STAGE"
  fi
  if [ -n "$PANDOC_BUILD_TMP" ]; then
    rm -f "$PANDOC_BUILD_TMP"
  fi
  if [ -n "$SPARKLE_STAGE" ]; then
    rm -rf "$SPARKLE_STAGE"
  fi
}
trap cleanup_build_stages EXIT
trap 'cleanup_build_stages; exit 130' INT
trap 'cleanup_build_stages; exit 143' TERM

# fetch_verified: Archiv aus dem Cache nehmen oder laden — in beiden Fällen erst
# nach bestandener SHA-256-Prüfung. `download_verified` prüft den Cache selbst;
# hier steht nur noch, welcher Weg gegangen wurde. Eine Funktion, weil pandoc,
# Sparkle und der pandoc-COPYRIGHT-Text sonst dreimal dieselbe if/else-Kette
# hätten — und ein vergessenes `|| exit 1` einen unverifizierten Build ergäbe.
fetch_verified() {
  local label="$1"
  local url="$2"
  local expected_sha256="$3"
  local destination="$4"

  if sha256_matches "$destination" "$expected_sha256"; then
    echo "✓ Verifiziertes $label aus Cache: $destination"
    return 0
  fi
  echo "==> Lade und verifiziere $url"
  download_verified "$url" "$expected_sha256" "$destination" || exit 1
}

PANDOC_ZIP="$CACHE_DIR/pandoc-${PANDOC_VERSION}-arm64.zip"
PANDOC_URL="https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-arm64-macOS.zip"
fetch_verified "pandoc-arm64" "$PANDOC_URL" "$PANDOC_ZIP_SHA256" "$PANDOC_ZIP"

# Immer aus dem verifizierten Archiv in ein privates Staging-Verzeichnis
# entpacken. Nur der dokumentierte Archivpfad ist zulässig; ein zusätzlich
# eingeschleustes ausführbares `pandoc` kann nicht ausgewählt werden.
PANDOC_ARCHIVE_ROOT="pandoc-${PANDOC_VERSION}-arm64"
PANDOC_ARCHIVE_BIN="$PANDOC_ARCHIVE_ROOT/bin/pandoc"
PANDOC_STAGE=$(mktemp -d "$BUILD_DIR/.pandoc-extract.XXXXXX")
PANDOC_BUILD_TMP=$(mktemp "$BUILD_DIR/.pandoc-binary.XXXXXX")

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

for helper in clipboard-html clipboard-rtf md-clip-hud; do
  src="$PROJECT_ROOT/helpers/${helper}.swift"
  out="$BUILD_DIR/${helper}"
  echo "==> Kompiliere ${helper}"
  # -target setzt sowohl Architektur als auch Mindest-OS-Version in einem.
  swiftc -target "arm64-apple-macos${MIN_MACOS}" "$src" -o "$out"
done

# ---------- 3. Sparkle laden und Updater-Helfer kompilieren ----------

# Sparkle liefert fertig gebaute, von den Sparkle-Entwicklern signierte
# Binaries als tar.xz. Wie bei pandoc gilt: nur verifiziert aus dem Cache,
# und nur die dokumentierten Archivpfade werden entpackt.
SPARKLE_TAR="$CACHE_DIR/Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
fetch_verified "Sparkle" "$SPARKLE_URL" "$SPARKLE_TAR_SHA256" "$SPARKLE_TAR"

SPARKLE_STAGE=$(mktemp -d "$BUILD_DIR/.sparkle-extract.XXXXXX")
tar -x -C "$SPARKLE_STAGE" -f "$SPARKLE_TAR" ./Sparkle.framework ./LICENSE

# Zusätzlich zur Prüfsumme: Die Signatur der Sparkle-Entwickler muss auf dem
# entpackten Framework intakt sein. Ein Archiv, dessen Framework diese Prüfung
# nicht besteht, kommt nicht ins Bundle.
codesign --verify --deep --strict "$SPARKLE_STAGE/Sparkle.framework"
test -s "$SPARKLE_STAGE/LICENSE"

echo "==> Kompiliere md-clip-updater"
# Der Updater-Helfer ist die Sparkle-Laufzeit der App: Er treibt Sparkle an
# (siehe helpers/md-clip-updater.swift). Der zweite Cocoa-Helfer im Bundle ist
# md-clip-hud, der die Erfolgsmeldung zeigt — beide gehören in Signatur- und
# Kompatibilitätsprüfungen. Gelinkt wird gegen das frisch entpackte Framework;
# zur Laufzeit findet der Updater es über den rpath im Bundle unter
# Contents/Frameworks.
swiftc -target "arm64-apple-macos${MIN_MACOS}" \
  -F "$SPARKLE_STAGE" \
  "$PROJECT_ROOT/helpers/md-clip-updater.swift" \
  -o "$BUILD_DIR/md-clip-updater" \
  -Xlinker -rpath -Xlinker "@loader_path/../Frameworks"

# ---------- 4. .app-Bundle-Struktur ----------

echo "==> Erstelle .app-Struktur"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources/bin"
mkdir -p "$APP_BUNDLE/Contents/Resources/Licenses"

# md-clip-Skript und Helper kopieren
cp "$PROJECT_ROOT/bin/md-clip"     "$APP_BUNDLE/Contents/Resources/bin/md-clip"
cp "$PROJECT_ROOT/lib/pipeline.sh" "$APP_BUNDLE/Contents/Resources/bin/pipeline.sh"
cp "$BUILD_DIR/clipboard-html"     "$APP_BUNDLE/Contents/Resources/bin/clipboard-html"
cp "$BUILD_DIR/clipboard-rtf"      "$APP_BUNDLE/Contents/Resources/bin/clipboard-rtf"
cp "$BUILD_DIR/pandoc"             "$APP_BUNDLE/Contents/Resources/bin/pandoc"

# Sparkle-Framework ins Bundle. `ditto` statt `cp -R`, weil Frameworks aus
# Symlinks bestehen (Sparkle -> Versions/Current/Sparkle) und dyld genau
# diese Struktur erwartet.
ditto "$SPARKLE_STAGE/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
# Die App ist nicht sandboxed. Sparkles XPC-Dienste sind damit weder aktiviert
# noch nötig — im Bundle wären sie nur nutzlose Angriffsfläche.
rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
rm -f  "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/XPCServices"

# Updater-Helfer neben den Launcher: In Contents/MacOS/ ist Bundle.main für
# den Helfer die md-clip.app — Sparkle liest Feed-URL und Schlüssel dann aus
# der Info.plist des Bundles, nicht aus einer zweiten Konstante im Code.
cp "$BUILD_DIR/md-clip-updater" "$APP_BUNDLE/Contents/MacOS/md-clip-updater"
chmod +x "$APP_BUNDLE/Contents/MacOS/md-clip-updater"

# HUD-Helfer neben Launcher und Updater. Er zeigt die Erfolgsmeldung als
# kurzes Einblend-Fenster der App selbst — dafür braucht es keinerlei
# macOS-Erlaubnis (Begründung und Vorgeschichte in helpers/md-clip-hud.swift).
cp "$BUILD_DIR/md-clip-hud" "$APP_BUNDLE/Contents/MacOS/md-clip-hud"
chmod +x "$APP_BUNDLE/Contents/MacOS/md-clip-hud"

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
    <!-- Sparkle. Die App sucht beim Start selbsttätig nach Updates (höchstens
         einmal je 24 Stunden, siehe helpers/md-clip-updater.swift), lädt und
         installiert aber ausschließlich nach Zustimmung. Anonyme Hardware-
         und Systemprofildaten werden nicht übertragen. Feed und Archiv müssen
         mit dem hier hinterlegten öffentlichen Ed25519-Schlüssel signiert
         sein; es ist dasselbe Schlüsselpaar wie bei Poor Man's Text und
         Fastra (siehe docs/SPARKLE-RELEASE.md). -->
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUEnableSystemProfiling</key>
    <false/>
    <key>SUFeedURL</key>
    <string>https://danielmuellerir.github.io/md-clip/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>Yo814iJMK/ZhDswOUNHuY+fW7ZxD3fRz9jFJRxnPeYY=</string>
    <key>SURequireSignedFeed</key>
    <true/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
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
fetch_verified "pandoc-COPYRIGHT" \
  "$PANDOC_COPYRIGHT_URL" \
  "$PANDOC_COPYRIGHT_SHA256" \
  "$PANDOC_COPYRIGHT_CACHE"
test -s "$PANDOC_COPYRIGHT_CACHE"
cp "$PANDOC_COPYRIGHT_CACHE" "$LIC_DIR/pandoc-COPYRIGHT.txt"

# Sparkles Lizenz (MIT) gehört wie die pandoc-Lizenz in die verteilte App,
# nicht nur ins Build-Verzeichnis. Sie kommt aus demselben verifizierten
# Archiv wie das Framework (Schritt 3).
cp "$SPARKLE_STAGE/LICENSE" "$LIC_DIR/Sparkle-LICENSE.txt"

cat > "$LIC_DIR/README.txt" <<NOTE
md-clip enthält ein unverändert weiterverteiltes pandoc-Binary
(Version ${PANDOC_VERSION}), veröffentlicht unter der GNU General
Public License (GPL). Der vollständige Lizenztext steht in
pandoc-COPYRIGHT.txt.

Pandoc-Quellcode: https://github.com/jgm/pandoc/tree/${PANDOC_VERSION}

Schriftliches Angebot (GPL): Der vollständige Quellcode dieser pandoc-
Version wird auf Anfrage für mindestens drei Jahre bereitgestellt.
Kontakt: siehe GitHub-Repo DanielMuellerIR/md-clip (Issues oder Discussions)

Außerdem enthält md-clip das Update-Framework Sparkle
(Version ${SPARKLE_VERSION}, MIT-Lizenz, siehe Sparkle-LICENSE.txt).
Sparkle-Quellcode: https://github.com/sparkle-project/Sparkle

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
