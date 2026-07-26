#!/usr/bin/env bash
# release.sh — Release-DMG bauen: App bauen, signieren, notarisieren, DMG packen
# und notarisieren.
#
# Die Einstiegspunkte des Projekts trennen bewusst:
#   ./build.sh        baut md-clip.app nach build/, ohne zu signieren
#   ./install.sh      richtet die CLI ein (macOS und Linux) — keine App
#   ./install-app.sh  baut, notarisiert und installiert die App nach /Applications
#   ./release.sh      baut, notarisiert und packt das DMG — installiert NIE
#
# Die eigentliche Arbeit macht wrappers/sign-and-release.sh; dieses Skript ist
# der einheitliche Einstiegspunkt nach dem projektübergreifenden Schema und
# reicht alle Argumente durch.
#
# Wichtig ist die doppelte Notarisierung: Erst bekommt die App ihr eigenes
# Ticket angeheftet, dann das fertige DMG. Nur so startet sie auch dann sauber,
# wenn jemand sie aus dem Image herauszieht — ein Ticket allein am DMG reicht
# dafür nicht.
#
# Voraussetzungen:
#   - "Developer ID Application"-Zertifikat im Schlüsselbund
#   - notarytool-Profil: NOTARY_PROFILE oder `git config mdClip.notaryProfile`
#
# Aufruf:
#   ./release.sh                     # vollständiger Release-Lauf
#   ./release.sh --no-finder-layout  # ohne Finder-Fensterlayout (headless)
set -euo pipefail
cd "$(dirname "$0")"
exec bash wrappers/sign-and-release.sh "$@"
