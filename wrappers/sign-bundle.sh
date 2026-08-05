#!/usr/bin/env bash
# wrappers/sign-bundle.sh — Signiert das md-clip.app-Bundle von innen nach
# außen. install-app.sh und sign-and-release.sh rufen dieses Skript auf;
# die Reihenfolge der verschachtelten Signaturen steht damit nur an einer
# Stelle und kann zwischen Installation und Release nicht auseinanderlaufen.
#
# Aufruf: sign-bundle.sh <App-Bundle> <Codesign-Identität>
#
# Reihenfolge (innen nach außen — jede äußere Signatur versiegelt die
# inneren mit):
#   1. Binaries in Contents/Resources/bin/ (pandoc, clipboard-html,
#      clipboard-rtf). Die Shell-Skripte daneben (md-clip, pipeline.sh)
#      brauchen keine eigene Signatur; sie werden als Ressourcen vom
#      Bundle-Siegel erfasst.
#   2. Der Updater-Helfer in Contents/MacOS/. codesign signiert beim
#      Bundle-Aufruf nur das Haupt-Executable (den Launcher) — ein zweites
#      Programm im selben Verzeichnis muss ausdrücklich selbst signiert werden.
#   3. Sparkles Helfer im Framework: erst das Autoupdate-Programm, dann die
#      Updater-App, dann das Framework selbst. `--deep` wäre beim Signieren
#      falsch (Apple rät ab, und es überschreibt die verschachtelten
#      Signaturgrenzen stumpf) — es bleibt allein der abschließenden
#      Prüfung vorbehalten.
#   4. Das App-Bundle.
#
# --options runtime: Hardened Runtime, Pflicht für Notarization seit 2020.
# --timestamp:       Apples Zeitstempeldienst; die Signatur bleibt auch nach
#                    Ablauf des Zertifikats gültig.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Aufruf: sign-bundle.sh <App-Bundle> <Codesign-Identität>" >&2
  exit 64
fi

APP="$1"
IDENTITY="$2"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

[ -d "$APP" ] || { echo "App-Bundle fehlt: $APP" >&2; exit 66; }

# Fail-closed: Jedes Signaturziel muss existieren. Ein Bundle ohne Updater
# oder ohne Sparkle wäre ein kaputter Build — der darf nicht halb signiert
# durchrutschen.
SIGN_TARGETS=(
  "$APP/Contents/Resources/bin/pandoc"
  "$APP/Contents/Resources/bin/clipboard-html"
  "$APP/Contents/Resources/bin/clipboard-rtf"
  "$APP/Contents/MacOS/md-clip-updater"
  "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
  "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
  "$SPARKLE_FRAMEWORK"
)

for target in "${SIGN_TARGETS[@]}"; do
  [ -e "$target" ] || { echo "Signaturziel fehlt: $target" >&2; exit 66; }
done

# Quarantäne-/Finder-Metadaten dürfen die versiegelte Signatur nicht verändern.
xattr -cr "$APP"

for target in "${SIGN_TARGETS[@]}"; do
  echo "   Signiere $(basename "$target")"
  codesign --sign "$IDENTITY" \
           --options runtime \
           --timestamp \
           --force \
           "$target"
done

echo "   Signiere App-Bundle"
codesign --sign "$IDENTITY" \
         --options runtime \
         --timestamp \
         --force \
         "$APP"

# Verifikation: --deep prüft hier auch alle verschachtelten Signaturen und
# bricht ab, wenn eine kaputt oder unvollständig ist.
codesign --verify --deep --strict --verbose=2 "$APP"
