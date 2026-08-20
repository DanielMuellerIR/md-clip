#!/usr/bin/env bash
# install-app.sh — md-clip.app notarisiert nach /Applications installieren.
#
# Die Einstiegspunkte des Projekts trennen bewusst:
#   ./build.sh        baut md-clip.app nach build/, ohne zu signieren
#   ./install.sh      richtet die CLI ein (macOS und Linux) — keine App
#   ./install-app.sh  baut, notarisiert und installiert die App nach /Applications
#   ./release.sh      baut, notarisiert und packt das DMG — installiert nie
#
# Warum getrennt von install.sh: Das ist das plattformübergreifende Setup für
# den Befehl `md-clip` und läuft auch auf Linux. Der App-Weg hier ist macOS-only
# und verlangt ein Developer-ID-Zertifikat — das gehört nicht in ein Setup, das
# jeder ausführen soll. Die App enthält ihre eigene CLI samt Abhängigkeiten;
# `install.sh` ist der alternative Weg direkt aus dem Git-Clone und wird vor
# oder nach dieser App-Installation nicht benötigt.
#
# In /Applications gehören nur Bundles mit angeheftetem Notary-Ticket, die
# Gatekeeper akzeptiert; dieses Skript prüft das vor UND nach dem Kopieren.
#
# Voraussetzungen:
#   - "Developer ID Application"-Zertifikat im Schlüsselbund
#   - notarytool-Profil: NOTARY_PROFILE oder `git config mdClip.notaryProfile`
#
# Aufruf:  ./install-app.sh
# Letzte Zeile bei Erfolg: INSTALL OK: /Applications/md-clip.app (<version>)
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_ROOT="$PWD"
# shellcheck source=wrappers/notarization.sh
source wrappers/notarization.sh

APP="build/md-clip.app"
DESTINATION="/Applications/md-clip.app"
VERSION="$(grep '^VERSION=' bin/md-clip | head -1 | cut -d'"' -f2)"

# Alles Temporäre hängt an diesen beiden Variablen und wird von EINER
# Aufräumroutine erledigt. Der Trap steht vor dem ersten `mktemp`: Scheitert
# `ditto` oder die Notarisierung, bleibt sonst ein großes App-Archiv liegen.
# Eine erledigte Zwischenstufe leert ihre Variable und fällt damit aus der
# Zuständigkeit heraus.
NOTARY_APP_ZIP_DIR=""
STAGED=""
cleanup_install() {
  cleanup_notary_archive
  if [ -n "$STAGED" ]; then
    rm -rf "$STAGED"
  fi
}
trap cleanup_install EXIT
trap 'cleanup_install; exit 130' INT
trap 'cleanup_install; exit 143' TERM

resolve_notary_profile "$PROJECT_ROOT" || exit $?

# Fail-fast VOR dem Bauen: Ein unbrauchbares Profil erst nach dem Bauen zu
# bemerken, kostet nur Zeit.
#
# Mit Wiederholungen, weil der Aufruf gelegentlich fälschlich „No Keychain
# password item found" meldet, obwohl das Profil da ist (am 2026-07-26 belegt).
# Ein wirklich fehlendes Profil scheitert auch nach fünf Versuchen.
TEAM_ID="${APPLE_TEAM_ID:-9QSWKSR4NQ}"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Daniel Mueller ($TEAM_ID)}"
verify_notary_profile "$NOTARY_PROFILE" "$TEAM_ID" || exit 2
require_signing_identity "$IDENTITY" || exit 1

echo "=== 1/4 App bauen ==="
bash wrappers/build-app-bundled.sh
[ -d "$APP" ] || { echo "FEHLER: Erwartetes Bundle fehlt: $APP" >&2; exit 1; }

echo "=== 2/4 Signieren (innere Binaries zuerst) ==="
# Reihenfolge (innen nach außen, inkl. Sparkle-Framework und Updater-Helfer)
# steht zentral in wrappers/sign-bundle.sh — dieselbe Datei benutzt auch
# der Release-Weg, damit Installation und Release nicht auseinanderlaufen.
bash wrappers/sign-bundle.sh "$APP" "$IDENTITY"
bash wrappers/verify-bundle.sh "$APP" --signed --team-id "$TEAM_ID"

echo "=== 3/4 Notarisieren ==="
notarize_app_bundle "$APP" "$NOTARY_PROFILE"

echo "=== 4/4 Installieren ==="
# Erst neben das Ziel legen, dann atomar austauschen: ein Abbruch mittendrin
# darf keine halb ersetzte App in /Applications hinterlassen.
STAGED="/Applications/.md-clip.app.install-$$"
rm -rf "$STAGED"
ditto "$APP" "$STAGED"
/usr/bin/swift - "$STAGED" "$DESTINATION" <<'SWIFT'
import Foundation

let fileManager = FileManager.default
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
if fileManager.fileExists(atPath: destination.path) {
    _ = try fileManager.replaceItemAt(
        destination,
        withItemAt: source,
        backupItemName: nil,
        options: [.usingNewMetadataOnly]
    )
} else {
    try fileManager.moveItem(at: source, to: destination)
}
SWIFT
# Der Zwischenstand ist verschoben, es gibt nichts mehr aufzuräumen.
STAGED=""

# Nach dem Kopieren erneut prüfen: erst dann ist die Installation belegt.
xcrun stapler validate "$DESTINATION"
spctl -a -t exec -vv "$DESTINATION" 2>&1 | tail -2

echo "INSTALL OK: $DESTINATION ($VERSION)"
