#!/usr/bin/env bash
# wrappers/verify-bundle.sh — Prüft das gebaute md-clip.app-Bundle als
# Produkt, unabhängig vom Build-Weg. build.sh ruft es strukturell auf,
# install-app.sh und sign-and-release.sh zusätzlich mit --signed.
#
# Aufruf: verify-bundle.sh <App-Bundle> [--signed]
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Aufruf: verify-bundle.sh <App-Bundle> [--signed]" >&2
  exit 64
fi

APP="$1"
SIGNED=0
case "${2:-}" in
  "") ;;
  --signed) SIGNED=1 ;;
  *) echo "Unbekannte Option: $2" >&2; exit 64 ;;
esac

INFO_PLIST="$APP/Contents/Info.plist"
LAUNCHER="$APP/Contents/MacOS/md-clip"
UPDATER="$APP/Contents/MacOS/md-clip-updater"
BUNDLED_CLI="$APP/Contents/Resources/bin/md-clip"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

# ---------- Struktur ----------

[ -f "$INFO_PLIST" ] || { echo "Info.plist fehlt im Bundle." >&2; exit 66; }
[ -x "$LAUNCHER" ]   || { echo "Launcher fehlt im Bundle." >&2; exit 66; }
[ -x "$UPDATER" ]    || { echo "Updater-Helfer fehlt im Bundle." >&2; exit 66; }
[ -x "$APP/Contents/MacOS/md-clip-hud" ] || {
  echo "HUD-Helfer fehlt im Bundle." >&2
  exit 66
}
for tool in md-clip pipeline.sh pandoc clipboard-html clipboard-rtf; do
  [ -x "$APP/Contents/Resources/bin/$tool" ] || {
    echo "Werkzeug fehlt im Bundle: Resources/bin/$tool" >&2
    exit 66
  }
done
for license in pandoc-COPYRIGHT.txt Sparkle-LICENSE.txt README.txt; do
  [ -s "$APP/Contents/Resources/Licenses/$license" ] || {
    echo "Lizenzdatei fehlt im Bundle: $license" >&2
    exit 66
  }
done

# Ohne das Framework startet der Updater nicht, und ohne Sparkles
# Updater-Programme bliebe eine Aktualisierung beim Austausch der App stehen.
[ -d "$SPARKLE_FRAMEWORK" ] || { echo "Sparkle.framework fehlt im Bundle." >&2; exit 66; }
[ -x "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" ] || {
  echo "Sparkles Autoupdate-Programm fehlt im Bundle." >&2
  exit 66
}
[ -d "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" ] || {
  echo "Sparkles Updater-App fehlt im Bundle." >&2
  exit 66
}
# Die App ist nicht sandboxed; Sparkles XPC-Dienste gehören deshalb nicht ins
# ausgelieferte Bundle. Sie wären nur nutzlose Angriffsfläche.
if [ -e "$SPARKLE_FRAMEWORK/Versions/B/XPCServices" ] \
   || [ -e "$SPARKLE_FRAMEWORK/XPCServices" ]; then
  echo "Sparkles XPC-Dienste sind noch im Bundle." >&2
  exit 65
fi

# ---------- Updater-Verlinkung ----------

# Der Helfer muss Sparkle über den rpath im Bundle finden — sonst startet er
# nur auf dem Build-Mac (wo das Staging-Verzeichnis noch existiert).
if ! otool -l "$UPDATER" | grep -Fq '@loader_path/../Frameworks'; then
  echo "Updater-Helfer hat keinen rpath auf Contents/Frameworks." >&2
  exit 65
fi
if ! otool -L "$UPDATER" | grep -Fq '@rpath/Sparkle.framework'; then
  echo "Updater-Helfer ist nicht gegen Sparkle über @rpath gelinkt." >&2
  exit 65
fi

# ---------- Update-Konfiguration ----------

# Der Updater darf nur einem signierten Feed über HTTPS folgen. Fehlt der
# öffentliche Schlüssel, ließe sich jedes beliebige Archiv unterschieben.
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST" 2>/dev/null || true)"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST" 2>/dev/null || true)"
case "$FEED_URL" in
  https://*) ;;
  *) echo "SUFeedURL fehlt oder benutzt kein HTTPS: ${FEED_URL:-<leer>}" >&2; exit 65 ;;
esac
[ -n "$PUBLIC_KEY" ] || { echo "SUPublicEDKey fehlt in der Info.plist." >&2; exit 65; }

# ---------- Versionsgleichheit ----------

# Info.plist und eingebettete CLI müssen dieselbe Version melden — beide
# stammen aus derselben Quelle (VERSION= in bin/md-clip), aber genau das
# soll hier am Produkt belegt und nicht nur dem Build geglaubt werden.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
# Erst vollständig einlesen, dann die erste Zeile nehmen. `--version | head -1`
# wäre unter `set -o pipefail` ein SIGPIPE-Abbruch (Exit 141): head schließt
# die Pipe nach der ersten Zeile, während md-clip noch weiterschreibt.
CLI_OUTPUT="$("$BUNDLED_CLI" --version)"
CLI_VERSION="${CLI_OUTPUT%%$'\n'*}"
if [ "$CLI_VERSION" != "md-clip $PLIST_VERSION" ]; then
  echo "App- und CLI-Version stimmen nicht überein: '$CLI_VERSION' vs '$PLIST_VERSION'." >&2
  exit 65
fi

# ---------- Signaturen ----------

if [ "$SIGNED" -eq 1 ]; then
  codesign --verify --deep --strict --verbose=2 "$APP"

  verify_distribution_signature() {
    local executable="$1"
    local label="$2"
    local signature_details
    signature_details="$(codesign -d --verbose=4 "$executable" 2>&1)"
    if ! printf '%s\n' "$signature_details" | grep -q 'flags=.*runtime'; then
      echo "Hardened Runtime fehlt in der $label-Signatur." >&2
      exit 65
    fi
    if ! printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:'; then
      echo "Developer-ID-Application-Autorität fehlt in der $label-Signatur." >&2
      exit 65
    fi
    if ! printf '%s\n' "$signature_details" | grep -q '^Timestamp='; then
      echo "Sicherer Zeitstempel fehlt in der $label-Signatur." >&2
      exit 65
    fi
  }

  verify_distribution_signature "$APP" "App"
  verify_distribution_signature "$UPDATER" "Updater-Helfer"
  verify_distribution_signature "$APP/Contents/MacOS/md-clip-hud" "HUD-Helfer"
  # Sparkle kommt fertig gebaut von außen und wird beim Signieren neu
  # gesiegelt. Diese Prüfung stellt sicher, dass die eigene Developer ID
  # wirklich auf Framework, Updater-App und Autoupdate liegt — sonst
  # verweigert die Notarisierung später den ganzen Lauf.
  verify_distribution_signature "$SPARKLE_FRAMEWORK" "Sparkle-Framework"
  verify_distribution_signature "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" "Sparkle-Updater"
  verify_distribution_signature "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" "Sparkle-Autoupdate"
  verify_distribution_signature "$APP/Contents/Resources/bin/pandoc" "pandoc"
fi

echo "VERIFY OK: $APP ($PLIST_VERSION)"
