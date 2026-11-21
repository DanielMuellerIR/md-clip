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
# shellcheck source=wrappers/version.sh
source wrappers/version.sh

# shellcheck source=wrappers/verify-built-cli.sh
source wrappers/verify-built-cli.sh

bash wrappers/build-app-bundled.sh

APP="build/md-clip.app"
[ -d "$APP" ] || { echo "FEHLER: Erwartetes Bundle fehlt: $APP" >&2; exit 1; }

# Strukturprüfung des Produkts (Werkzeuge, Sparkle, Lizenzen, Versionen) —
# das Bundle wird geprüft, nicht dem Build geglaubt.
bash wrappers/verify-bundle.sh "$APP"

SOURCE_VERSION="$(md_clip_version bin/md-clip || true)"
[ -n "$SOURCE_VERSION" ] || { echo "FEHLER: VERSION fehlt in bin/md-clip." >&2; exit 65; }
verify_trusted_build_cli \
  "bin/md-clip" \
  "$APP/Contents/Resources/bin/md-clip" \
  "$SOURCE_VERSION"

echo "BUILD OK: $PWD/$APP"
