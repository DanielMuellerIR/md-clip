#!/usr/bin/env bash
# build.sh — md-clip.app bauen, mehr nicht.
#
# Die Einstiegspunkte des Projekts trennen bewusst:
#   ./build.sh        baut md-clip.app nach build/, ohne zu signieren
#   ./install.sh      richtet die CLI ein (macOS und Linux) — keine App
#   ./install-app.sh  baut, notarisiert und installiert die App nach /Applications
#   ./release.sh      baut, notarisiert und packt das DMG — installiert nie
#
# Warum install.sh hier nicht die App installiert: Es ist das
# plattformübergreifende Setup für den Befehl `md-clip` (Symlink, Swift-Helfer)
# und läuft auch auf Linux. Der App-Weg ist macOS-only und braucht ein
# Developer-ID-Zertifikat — das gehört nicht in das Setup, das jeder ausführt.
#
# Die Arbeit macht wrappers/build-app-bundled.sh; dieses Skript ist nur der
# einheitliche Einstiegspunkt nach dem projektübergreifenden Schema.
#
# Aufruf:  ./build.sh
# Letzte Zeile bei Erfolg: BUILD OK: <pfad-zur-app>
set -euo pipefail
cd "$(dirname "$0")"

# BEGIN TRUSTED_BUILD_CLI_SMOKE
verify_trusted_build_cli() {
  local source_cli="$1"
  local bundled_cli="$2"
  local expected_version="$3"
  local version_output actual_version

  # Ein lokaler Build ist noch nicht signiert. Deshalb darf der allgemeine
  # Bundle-Pruefer das darin enthaltene Skript nicht blind ausfuehren. Hier
  # kennen wir dagegen Quelle und Ziel desselben Build-Laufs und binden beide
  # erst bytegenau aneinander, bevor wir den eingebetteten Befehl starten.
  if ! cmp -s "$source_cli" "$bundled_cli"; then
    echo "FEHLER: Eingebettete CLI stimmt nicht mit bin/md-clip ueberein." >&2
    return 65
  fi
  if ! bash -n "$bundled_cli"; then
    echo "FEHLER: Eingebettete CLI hat einen Syntaxfehler." >&2
    return 65
  fi
  if ! version_output="$("$bundled_cli" --version)"; then
    echo "FEHLER: Eingebettete CLI laesst sich nicht ausfuehren." >&2
    return 65
  fi
  actual_version="${version_output%%$'\n'*}"
  if [ "$actual_version" != "md-clip $expected_version" ]; then
    echo "FEHLER: Eingebettete CLI meldet '$actual_version' statt 'md-clip $expected_version'." >&2
    return 65
  fi
}
# END TRUSTED_BUILD_CLI_SMOKE

bash wrappers/build-app-bundled.sh

APP="build/md-clip.app"
[ -d "$APP" ] || { echo "FEHLER: Erwartetes Bundle fehlt: $APP" >&2; exit 1; }

# Strukturprüfung des Produkts (Werkzeuge, Sparkle, Lizenzen, Versionen) —
# das Bundle wird geprüft, nicht dem Build geglaubt.
bash wrappers/verify-bundle.sh "$APP"

SOURCE_VERSION="$(awk -F'"' '/^VERSION=/{print $2; exit}' bin/md-clip)"
[ -n "$SOURCE_VERSION" ] || { echo "FEHLER: VERSION fehlt in bin/md-clip." >&2; exit 65; }
verify_trusted_build_cli \
  "bin/md-clip" \
  "$APP/Contents/Resources/bin/md-clip" \
  "$SOURCE_VERSION"

echo "BUILD OK: $PWD/$APP"
