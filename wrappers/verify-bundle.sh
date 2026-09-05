#!/usr/bin/env bash
# wrappers/verify-bundle.sh — Prüft das gebaute md-clip.app-Bundle als
# Produkt, unabhängig vom Build-Weg. build.sh ruft es strukturell auf,
# install-app.sh und sign-and-release.sh zusätzlich mit --signed.
#
# Aufruf: verify-bundle.sh <App-Bundle> [--signed] [--team-id TEAM_ID]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=verify-bundle-trust.sh
source "$SCRIPT_DIR/verify-bundle-trust.sh"
# shellcheck source=version.sh
source "$SCRIPT_DIR/version.sh"

if [ "$#" -lt 1 ]; then
  echo "Aufruf: verify-bundle.sh <App-Bundle> [--signed] [--team-id TEAM_ID]" >&2
  exit 64
fi

APP="$1"
shift
SIGNED=0
EXPECTED_TEAM_ID="$DEFAULT_TEAM_ID"
TEAM_ID_EXPLICIT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --signed)
      SIGNED=1
      ;;
    --team-id)
      shift
      [ "$#" -gt 0 ] || { echo "--team-id braucht einen Wert." >&2; exit 64; }
      EXPECTED_TEAM_ID="$1"
      TEAM_ID_EXPLICIT=1
      ;;
    *) echo "Unbekannte Option: $1" >&2; exit 64 ;;
  esac
  shift
done
if [ "$TEAM_ID_EXPLICIT" -eq 1 ] && [ "$SIGNED" -ne 1 ]; then
  echo "--team-id ist nur zusammen mit --signed erlaubt." >&2
  exit 64
fi
if ! [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Ungueltige Apple-Team-ID: $EXPECTED_TEAM_ID" >&2
  exit 64
fi

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
for resource in tidy-markdown.pl tables.lua; do
  [ -s "$APP/Contents/Resources/bin/$resource" ] && [ -r "$APP/Contents/Resources/bin/$resource" ] || {
    echo "Pipeline-Ressource fehlt oder ist leer: $resource" >&2
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
   || [ -L "$SPARKLE_FRAMEWORK/Versions/B/XPCServices" ] \
   || [ -e "$SPARKLE_FRAMEWORK/XPCServices" ] \
   || [ -L "$SPARKLE_FRAMEWORK/XPCServices" ]; then
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

# ---------- macOS-Kompatibilität ----------

MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST" 2>/dev/null || true)"

# BEGIN MACOS_COMPATIBILITY_CHECK
macos_version_at_most() {
  local actual="$1"
  local declared="$2"

  awk -v actual="$actual" -v declared="$declared" '
    BEGIN {
      actual_count = split(actual, actual_parts, ".")
      declared_count = split(declared, declared_parts, ".")
      for (i = 1; i <= 3; i++) {
        actual_part = (i <= actual_count ? actual_parts[i] : 0) + 0
        declared_part = (i <= declared_count ? declared_parts[i] : 0) + 0
        if (actual_part < declared_part) exit 0
        if (actual_part > declared_part) exit 1
      }
      exit 0
    }
  '
}

macho_minimum_versions() {
  local binary="$1"

  # Universal-Binaries besitzen je Architektur einen Load Command. Bei alten
  # SDKs heißt das Feld `version` unter LC_VERSION_MIN_MACOSX, bei neuen
  # `minos` unter LC_BUILD_VERSION; beide Formen werden vollständig gelesen.
  vtool -show-build "$binary" | awk '
    /cmd LC_VERSION_MIN_MACOSX/ { legacy = 1; next }
    legacy && $1 == "version" { print $2; legacy = 0; next }
    $1 == "minos" { print $2 }
  '
}

verify_macos_compatibility() {
  local declared="$1"
  local label="$2"
  local binary="$3"
  local minimums minimum

  if ! [[ "$declared" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Ungültige LSMinimumSystemVersion: ${declared:-<leer>}." >&2
    return 65
  fi
  if ! minimums="$(macho_minimum_versions "$binary")" || [ -z "$minimums" ]; then
    echo "macOS-Mindestversion fehlt oder ist nicht lesbar: $label." >&2
    return 65
  fi

  while IFS= read -r minimum; do
    if ! [[ "$minimum" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
      echo "Ungültige macOS-Mindestversion in $label: $minimum." >&2
      return 65
    fi
    if ! macos_version_at_most "$minimum" "$declared"; then
      echo "$label benötigt macOS $minimum, Info.plist verspricht aber $declared." >&2
      return 65
    fi
  done <<< "$minimums"
}

# Eine zentrale Zielmenge verhindert, dass Produkt und Regressionstest
# unterschiedliche Bundle-Bestandteile prüfen. Der markierte Block enthält
# bewusst auch den Aufruf: Der Test führt damit genau dieselbe Schleife aus.
verify_all_macos_compatibility() {
  local declared="$1"
  local labels=(
    "Updater-Helfer"
    "HUD-Helfer"
    "HTML-Helper"
    "RTF-Helper"
    "pandoc"
    "Sparkle-Framework"
    "Sparkle-Autoupdate"
    "Sparkle-Updater"
  )
  local binaries=(
    "$UPDATER"
    "$APP/Contents/MacOS/md-clip-hud"
    "$APP/Contents/Resources/bin/clipboard-html"
    "$APP/Contents/Resources/bin/clipboard-rtf"
    "$APP/Contents/Resources/bin/pandoc"
    "$SPARKLE_FRAMEWORK/Versions/B/Sparkle"
    "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
    "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
  )
  local index

  for index in "${!labels[@]}"; do
    verify_macos_compatibility \
      "$declared" "${labels[$index]}" "${binaries[$index]}"
  done
}

verify_all_macos_compatibility "$MINIMUM_SYSTEM_VERSION"
# END MACOS_COMPATIBILITY_CHECK

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

# ---------- Signaturen ----------
#
# Dieser Abschnitt steht VOR der Versionsprüfung, und das ist der Punkt: Die
# Versionsprüfung startet das Shell-Skript im übergebenen Bundle. Bei einem
# fremden oder beschädigten Release-Artefakt liefe damit fremder Code, bevor
# überhaupt feststeht, ob das Bundle vertrauenswürdig ist — die Prüfung würde
# es hinterher zwar ablehnen, der Schaden wäre aber schon angerichtet
# (Review-Fund 2026-08-06). Erst Vertrauensnachweis, dann Ausführung.

if [ "$SIGNED" -eq 1 ]; then
  # Diese Pruefung bindet das Bundle vor jeder Ausfuehrung seines eingebetteten
  # CLI-Skripts an Apples Developer-ID-Kette, unsere Team-ID und die Bundle-ID.
  verify_signed_bundle_trust "$APP" /usr/libexec/PlistBuddy codesign "$EXPECTED_TEAM_ID"

  verify_distribution_signature() {
    local executable="$1"
    local label="$2"
    local signature_details
    signature_details="$(codesign -d --verbose=4 "$executable" 2>&1)"
    if ! grep -q 'flags=.*runtime' <<<"$signature_details"; then
      echo "Hardened Runtime fehlt in der $label-Signatur." >&2
      exit 65
    fi
    if ! grep -q '^Authority=Developer ID Application:' <<<"$signature_details"; then
      echo "Developer-ID-Application-Autorität fehlt in der $label-Signatur." >&2
      exit 65
    fi
    if ! grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<<"$signature_details"; then
      echo "Unerwartete Team-ID in der $label-Signatur." >&2
      exit 65
    fi
    if ! grep -q '^Timestamp=' <<<"$signature_details"; then
      echo "Sicherer Zeitstempel fehlt in der $label-Signatur." >&2
      exit 65
    fi
  }

  verify_distribution_signature "$APP" "App"
  verify_distribution_signature "$UPDATER" "Updater-Helfer"
  verify_distribution_signature "$APP/Contents/MacOS/md-clip-hud" "HUD-Helfer"
  verify_distribution_signature "$APP/Contents/Resources/bin/clipboard-html" "HTML-Helfer"
  verify_distribution_signature "$APP/Contents/Resources/bin/clipboard-rtf" "RTF-Helfer"
  # Sparkle kommt fertig gebaut von außen und wird beim Signieren neu
  # gesiegelt. Diese Prüfung stellt sicher, dass die eigene Developer ID
  # wirklich auf Framework, Updater-App und Autoupdate liegt — sonst
  # verweigert die Notarisierung später den ganzen Lauf.
  verify_distribution_signature "$SPARKLE_FRAMEWORK" "Sparkle-Framework"
  verify_distribution_signature "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" "Sparkle-Updater"
  verify_distribution_signature "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" "Sparkle-Autoupdate"
  verify_distribution_signature "$APP/Contents/Resources/bin/pandoc" "pandoc"
else
  # Lokale, unsignierte Builds koennen keine Apple-Vertrauenskette belegen.
  # Ihre Bundle-ID wird trotzdem als Strukturvertrag geprueft; Produktcode
  # fuehren wir in diesem Pfad nicht aus.
  verify_bundle_identifier "$APP"
fi

# ---------- Versionsgleichheit ----------

# Info.plist und eingebettete CLI müssen dieselbe Version melden. Ein signiertes
# Release darf die CLI dafuer ausfuehren, weil seine Vertrauenskette oben schon
# feststeht. Beim unsignierten Build wird VERSION nur als Quelldatum gelesen.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
if [ "$SIGNED" -eq 1 ]; then
  # Erst vollständig einlesen, dann die erste Zeile nehmen. `--version | head`
  # würde unter pipefail den Produktstatus verlieren oder SIGPIPE erzeugen.
  CLI_OUTPUT="$("$BUNDLED_CLI" --version)"
  CLI_VERSION="${CLI_OUTPUT%%$'\n'*}"
else
  CLI_SOURCE_VERSION="$(md_clip_version "$BUNDLED_CLI" || true)"
  if [ -z "$CLI_SOURCE_VERSION" ]; then
    echo "Eingebettete CLI enthält keine lesbare VERSION-Zeile." >&2
    exit 65
  fi
  CLI_VERSION="md-clip $CLI_SOURCE_VERSION"
fi
if [ "$CLI_VERSION" != "md-clip $PLIST_VERSION" ]; then
  echo "App- und CLI-Version stimmen nicht überein: '$CLI_VERSION' vs '$PLIST_VERSION'." >&2
  exit 65
fi

echo "VERIFY OK: $APP ($PLIST_VERSION)"
