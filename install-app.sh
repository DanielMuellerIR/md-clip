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
# jeder ausführen soll. Die App ruft ohnehin nur die CLI auf, `install.sh` bleibt
# also der erste Schritt.
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

APP="build/md-clip.app"
DESTINATION="/Applications/md-clip.app"
VERSION="$(grep '^VERSION=' bin/md-clip | head -1 | cut -d'"' -f2)"

# Alles Temporäre hängt an diesen beiden Variablen und wird von EINER
# Aufräumroutine erledigt. Der Trap steht vor dem ersten `mktemp`: Scheitert
# `ditto` oder die Notarisierung, bleibt sonst ein großes App-Archiv liegen.
# Eine erledigte Zwischenstufe leert ihre Variable und fällt damit aus der
# Zuständigkeit heraus.
APP_ZIP_DIR=""
STAGED=""
cleanup_install() {
  if [ -n "$APP_ZIP_DIR" ]; then
    rm -rf "$APP_ZIP_DIR"
  fi
  if [ -n "$STAGED" ]; then
    rm -rf "$STAGED"
  fi
}
trap cleanup_install EXIT
trap 'cleanup_install; exit 130' INT
trap 'cleanup_install; exit 143' TERM

NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -z "$NOTARY_PROFILE" ]; then
  NOTARY_PROFILE="$(git config --local --get mdClip.notaryProfile 2>/dev/null || true)"
fi
if [ -z "$NOTARY_PROFILE" ]; then
  echo "FEHLER: Kein Notary-Profil bekannt." >&2
  echo "Entweder NOTARY_PROFILE setzen oder einmalig fuer diesen Clone:" >&2
  echo "  git config --local mdClip.notaryProfile <profil>" >&2
  exit 2
fi
export NOTARY_PROFILE

# Fail-fast VOR dem Bauen: Ein unbrauchbares Profil erst nach dem Bauen zu
# bemerken, kostet nur Zeit.
#
# Mit Wiederholungen, weil der Aufruf gelegentlich fälschlich „No Keychain
# password item found" meldet, obwohl das Profil da ist (am 2026-07-26 belegt).
# Ein wirklich fehlendes Profil scheitert auch nach fünf Versuchen.
notary_profile_works() {
  local attempt
  for attempt in 1 2 3 4 5; do
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}
if ! notary_profile_works; then
  echo "FEHLER: Das Notary-Profil '$NOTARY_PROFILE' ist auf diesem Mac nicht verwendbar." >&2
  echo "Über SSH ist der Login-Schlüsselbund gesperrt — dann in einer lokalen" >&2
  echo "Terminalsitzung erneut versuchen." >&2
  exit 2
fi

TEAM_ID="${APPLE_TEAM_ID:-9QSWKSR4NQ}"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Daniel Mueller ($TEAM_ID)}"
if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
  echo "FEHLER: Signing-Identität nicht gefunden: $IDENTITY" >&2
  exit 1
fi

echo "=== 1/4 App bauen ==="
bash wrappers/build-app-bundled.sh
[ -d "$APP" ] || { echo "FEHLER: Erwartetes Bundle fehlt: $APP" >&2; exit 1; }

echo "=== 2/4 Signieren (innere Binaries zuerst) ==="
# Reihenfolge (innen nach außen, inkl. Sparkle-Framework und Updater-Helfer)
# steht zentral in wrappers/sign-bundle.sh — dieselbe Datei benutzt auch
# der Release-Weg, damit Installation und Release nicht auseinanderlaufen.
bash wrappers/sign-bundle.sh "$APP" "$IDENTITY"
bash wrappers/verify-bundle.sh "$APP" --signed

echo "=== 3/4 Notarisieren ==="
# notarytool nimmt kein nacktes .app entgegen, deshalb der Umweg über ein ZIP.
APP_ZIP_DIR="$(mktemp -d)"
APP_ZIP="$APP_ZIP_DIR/md-clip.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -rf "$APP_ZIP_DIR"
APP_ZIP_DIR=""
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP" 2>&1 | tail -2

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
