#!/usr/bin/env bash
# Reine Vertrauenspruefung fuer ein signiertes md-clip.app-Bundle.
# Das Skript liest nur Metadaten und prueft Signaturen; Produktcode wird hier
# nie gestartet. Fuer isolierte Tests duerfen PlistBuddy und codesign durch
# Attrappen als ausdrueckliche Funktionsargumente eingesetzt werden; der
# normale Skriptaufruf akzeptiert keine Werkzeugpfade aus der Umgebung.

set -euo pipefail

EXPECTED_BUNDLE_ID="io.github.danielmuellerir.md-clip"
DEFAULT_TEAM_ID="9QSWKSR4NQ"

verify_bundle_identifier() {
  local app="$1"
  local plistbuddy="${2:-/usr/libexec/PlistBuddy}"
  local info_plist="$app/Contents/Info.plist"
  local actual_bundle_id

  actual_bundle_id="$("$plistbuddy" -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
  if [ "$actual_bundle_id" != "$EXPECTED_BUNDLE_ID" ]; then
    echo "Unerwartete Bundle-ID: ${actual_bundle_id:-<leer>} (erwartet: $EXPECTED_BUNDLE_ID)." >&2
    return 65
  fi
}

verify_signed_bundle_trust() {
  local app="$1"
  local plistbuddy="${2:-/usr/libexec/PlistBuddy}"
  local codesign="${3:-codesign}"
  local expected_team_id="${4:-$DEFAULT_TEAM_ID}"
  local signature_details requirement actual_team_id

  verify_bundle_identifier "$app" "$plistbuddy" || return

  # Apples Developer-ID-Kette, die erwartete Team-ID und die Bundle-ID werden
  # gemeinsam als Designated Requirement geprueft. Ein gueltig signiertes
  # Bundle eines anderen Developer-ID-Inhabers reicht damit nicht aus.
  requirement="anchor apple generic and identifier \"$EXPECTED_BUNDLE_ID\" and certificate leaf[subject.OU] = \"$expected_team_id\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
  "$codesign" --verify --deep --strict --verbose=2 \
    --test-requirement "=$requirement" "$app" || return $?

  signature_details="$("$codesign" -d --verbose=4 "$app" 2>&1)" || return $?
  actual_team_id="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$signature_details")"
  if [ "$actual_team_id" != "$expected_team_id" ]; then
    echo "Unerwartete Team-ID: ${actual_team_id:-<leer>} (erwartet: $expected_team_id)." >&2
    return 65
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [ "$#" -ne 1 ]; then
    echo "Aufruf: verify-bundle-trust.sh <App-Bundle>" >&2
    exit 64
  fi
  verify_signed_bundle_trust "$1"
fi
